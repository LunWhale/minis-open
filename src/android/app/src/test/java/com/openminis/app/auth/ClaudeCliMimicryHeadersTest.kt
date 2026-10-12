package com.openminis.app.auth

import com.openminis.app.ProductionSources
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [OpenMinis#360] Claude OAuth token exchange and refresh were answered with a
 * Cloudflare challenge instead of JSON: the endpoint was the retired
 * `console.anthropic.com` host, and the auth requests carried none of the
 * Claude CLI fingerprint that the chat path has always sent.
 *
 * Two things are pinned here, because each failed silently on its own. The
 * fingerprint is verified on a real request over MockWebServer — the header
 * list being correct is worthless if the builder chain never applies it. The
 * endpoint and the two call sites are verified against the production source,
 * since reaching them through `ClaudeOAuthManager` would need a `Context`, an
 * OAuth callback server and a live authorization code.
 */
class ClaudeCliMimicryHeadersTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** Header name → value exactly as the chat path sends them. */
    private val expected = mapOf(
        "User-Agent" to "claude-cli/2.1.280 (external, cli)",
        "X-Stainless-Lang" to "js",
        "X-Stainless-Package-Version" to "0.106.0",
        "X-Stainless-OS" to "Linux",
        "X-Stainless-Arch" to "arm64",
        "X-Stainless-Runtime" to "node",
        "X-Stainless-Runtime-Version" to "v24.18.0",
        "X-Stainless-Retry-Count" to "0",
        "X-Stainless-Timeout" to "600",
        "X-App" to "cli",
        "Anthropic-Dangerous-Direct-Browser-Access" to "true",
    )

    @Test
    fun `all eleven mimicry headers reach the wire`() {
        server.enqueue(MockResponse().setBody("""{"access_token":"t"}"""))

        val request = okhttp3.Request.Builder()
            .url(server.url("/v1/oauth/token"))
            .applyClaudeCliMimicryHeaders()
            .post("""{"grant_type":"refresh_token"}""".toRequestBody("application/json".toMediaType()))
            .build()
        OkHttpClient().newCall(request).execute().close()

        val recorded = server.takeRequest()
        assertEquals(11, expected.size)
        for ((name, value) in expected) {
            assertEquals("header $name", value, recorded.getHeader(name))
        }
    }

    @Test
    fun `anthropic-beta is not sent on the auth path`() {
        // The beta header advertises message-API capabilities and is
        // meaningless on a token request; the real CLI omits it here too.
        server.enqueue(MockResponse().setBody("{}"))

        val request = okhttp3.Request.Builder()
            .url(server.url("/v1/oauth/token"))
            .applyClaudeCliMimicryHeaders()
            .post("{}".toRequestBody("application/json".toMediaType()))
            .build()
        OkHttpClient().newCall(request).execute().close()

        assertNull(server.takeRequest().getHeader("anthropic-beta"))
    }

    @Test
    fun `helper applies every header the shared list declares`() {
        server.enqueue(MockResponse().setBody("{}"))

        val request = okhttp3.Request.Builder()
            .url(server.url("/v1/oauth/token"))
            .applyClaudeCliMimicryHeaders()
            .post("{}".toRequestBody("application/json".toMediaType()))
            .build()
        OkHttpClient().newCall(request).execute().close()

        val recorded = server.takeRequest()
        for ((name, value) in ClaudeCliMimicryHeaders.ALL) {
            assertEquals("declared header $name", value, recorded.getHeader(name))
        }
    }

    @Test
    fun `token endpoint is the claude_ai host`() {
        val src = ProductionSources.read("auth/ClaudeOAuthManager.kt")
        assertTrue(
            "tokenURL must post to claude.ai",
            src.contains("""override val tokenURL = "https://claude.ai/v1/oauth/token""""),
        )
    }

    @Test
    fun `the retired console host is not the endpoint anywhere`() {
        val src = ProductionSources.read("auth/ClaudeOAuthManager.kt")
        // The old host may still be NAMED in the comment explaining the move;
        // what must not come back is it being assigned as the endpoint.
        assertTrue(
            "console.anthropic.com must not be used as tokenURL",
            !src.contains("""tokenURL = "https://console.anthropic.com"""),
        )
    }

    @Test
    fun `both token exchange and refresh apply the fingerprint`() {
        val src = ProductionSources.read("auth/ClaudeOAuthManager.kt")
        // One call site is the code exchange, the other the silent refresh.
        // Refresh is the one a user hits repeatedly, so a fingerprint on only
        // the login path would look fixed and fail days later.
        assertEquals(
            "both OAuth request builders must apply the fingerprint",
            2,
            Regex("\\.applyClaudeCliMimicryHeaders\\(\\)").findAll(src).count(),
        )
        assertEquals(
            "no OAuth request may be built without it",
            2,
            Regex("okhttp3\\.Request\\.Builder\\(\\)").findAll(src).count(),
        )
    }

    @Test
    fun `fingerprint matches the chat path in AnthropicProvider`() {
        // The values are one registered client identity. A fingerprint that
        // matches on chat but not on auth is the exact shape of OpenMinis#360,
        // so this fails if either side is bumped alone.
        val chat = ProductionSources.read("provider/anthropic/AnthropicProvider.kt")
        for ((name, value) in ClaudeCliMimicryHeaders.ALL) {
            assertTrue(
                "AnthropicProvider must still send $name: $value",
                chat.contains("""builder.header("$name", "$value")"""),
            )
        }
    }
}
