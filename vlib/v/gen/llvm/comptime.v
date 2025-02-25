module llvm

import v.ast
import v.pref

pub fn (mut g Gen) comptime_cond(cond ast.Expr, pkg_exists bool) bool {
	match cond {
		ast.BoolLiteral {
			return cond.val
		}
		ast.ParExpr {
			g.comptime_cond(cond.expr, pkg_exists)
		}
		ast.PrefixExpr {
			if cond.op == .not {
				return !g.comptime_cond(cond.right, pkg_exists)
			}
		}
		ast.InfixExpr {
			match cond.op {
				.and {
					return g.comptime_cond(cond.left, pkg_exists)
						&& g.comptime_cond(cond.right, pkg_exists)
				}
				.logical_or {
					return g.comptime_cond(cond.left, pkg_exists)
						|| g.comptime_cond(cond.right, pkg_exists)
				}
				.eq {
					return g.comptime_cond(cond.left, pkg_exists) == g.comptime_cond(cond.right,
						pkg_exists)
				}
				.ne {
					return g.comptime_cond(cond.left, pkg_exists) != g.comptime_cond(cond.right,
						pkg_exists)
				}
				// TODO: support generics
				// .key_is, .not_is
				else {}
			}
		}
		ast.Ident {
			return g.comptime_if_to_ifdef(cond.name, false)
		}
		ast.ComptimeCall {
			return pkg_exists // more documentation needed here...
		}
		else {}
	}
	g.w_error('${@FN}: unhandled node: ' + cond.type_name())
}

pub fn (mut g Gen) comptime_if_expr(node ast.IfExpr) {
	if !node.is_expr && !node.has_else && node.branches.len == 1 {
		if node.branches[0].stmts.len == 0 {
			// empty ifdef; result of target OS != conditional => skip
			return
		}
	}

	for i, branch in node.branches {
		has_expr := !(node.has_else && i + 1 >= node.branches.len)

		if has_expr && !g.comptime_cond(branch.cond, branch.pkg_exist) {
			continue
		}
		// !node.is_expr || cond
		// handles else case, and if cond is true
		g.gen_stmts(branch.stmts)
		break
	}
}

pub fn (mut g Gen) comptime_if_to_ifdef(name string, is_comptime_option bool) bool {
	match name {
		'js_node', 'js_freestanding', 'js_browser', 'es5', 'js', 'native', 'gcc', 'tinyc', 'mingw',
		'msvc', 'cplusplus', 'prealloc', 'freestanding', 'amd64', 'aarch64', 'arm64', 'wasm' {
			return false
		}
		'clang' {
			return true
		}
		'windows', 'ios', 'macos', 'mach', 'darwin', 'linux', 'freebsd', 'openbsd', 'bsd',
		'android', 'solaris' {
			return g.pref.os == pref.os_from_string(name) or { return false }
		}
		'llvm' {
			return true
		}
		'gcboehm' {
			return g.pref.gc_mode in [.boehm_leak, .boehm_incr_opt, .boehm_full_opt, .boehm_incr,
				.boehm_full]
		}
		'glibc' {
			return g.pref.is_glibc
		}
		'musl' {
			return g.pref.is_musl
		}
		'debug' {
			return g.pref.is_debug
		}
		'prod' {
			return g.pref.is_prod
		}
		'test' {
			return g.pref.is_test
		}
		'threads' {
			return true // TODO:
		}
		'no_bounds_checking' {
			return g.pref.no_bounds_checking
		}
		// bitness:
		'x64' {
			return g.pref.arch in [.amd64, .arm64, .rv64] // or g.pref.m64 ???
		}
		'x32' {
			return g.pref.arch in [.i386, .arm32, .rv32, .wasm32] // TODO: wasm ?!?!
		}
		// endianness:
		'little_endian' {
			return true // TODO: make it configurable
		}
		'big_endian' {
			return false
		}
		else {}
	}
	g.w_error('${@FN}: unhandled `${name}`, is_comptime_option: ${is_comptime_option}')
}
