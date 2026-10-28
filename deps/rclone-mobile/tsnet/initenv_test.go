package tsnet

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

// No package init in this module may change the process environment. In the
// c-archive the inits run on the Go runtime's own thread while the app's main
// thread starts up, and with cgo os.Setenv is C setenv, which reallocates
// environ under any thread reading it - JavaScriptCore read a stale entry and
// crashed the app at launch (crash point DuiHLbR5LJLQEkIH5Mp4xj). Set such
// values when the feature starts (see Start).
func TestNoInitChangesTheEnvironment(t *testing.T) {
	banned := []string{"Setenv", "Unsetenv", "Clearenv", "Putenv"}
	fset := token.NewFileSet()
	checked := 0
	err := filepath.WalkDir("..", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		checked++
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil || fn.Name.Name != "init" || fn.Body == nil {
				continue
			}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				sel, ok := n.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				for _, b := range banned {
					if sel.Sel.Name == b {
						t.Errorf("%s: init() calls %s", fset.Position(sel.Pos()), b)
					}
				}
				return true
			})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if checked < 5 {
		t.Fatalf("only %d Go files checked; the walk missed the module", checked)
	}
}
