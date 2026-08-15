/*
 * lua_compat.c — compatibility shims for OpenMinis.
 *
 * Lua 5.4 defines several API entry points as macros (lua_pcall → lua_pcallk,
 * lua_tostring → lua_tolstring, lua_tonumber → lua_tonumberx, lua_pop →
 * lua_settop, lua_newtable → lua_createtable, luaL_loadbuffer →
 * luaL_loadbufferx). Swift's @_silgen_name links against real symbols, so we
 * export the macro-named functions here. Parenthesized names suppress macro
 * expansion (same idiom as lua.c / lauxlib.c internals).
 */
#include "lua.h"
#include "lauxlib.h"

int (luaL_loadbuffer)(lua_State *L, const char *buff, size_t size, const char *name) {
    return luaL_loadbufferx(L, buff, size, name, NULL);
}

int (lua_pcall)(lua_State *L, int nargs, int nresults, int errfunc) {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, NULL);
}

const char *(lua_tostring)(lua_State *L, int idx) {
    return lua_tolstring(L, idx, NULL);
}

lua_Number (lua_tonumber)(lua_State *L, int idx) {
    return lua_tonumberx(L, idx, NULL);
}

void (lua_pop)(lua_State *L, int n) {
    lua_settop(L, -(n) - 1);
}

void (lua_newtable)(lua_State *L) {
    lua_createtable(L, 0, 0);
}
