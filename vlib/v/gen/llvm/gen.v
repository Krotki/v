module llvm

import v.ast
import v.util
import v.token
import v.pref
import strings
import os
import term
import math

@[heap; minify]
pub struct Gen {
	out_name string
	pref     &pref.Preferences = unsafe { nil } // Preferences shared from V struct
	files    []&ast.File
	is_debug bool
mut:
	file             &ast.File  = unsafe { nil }
	table            &ast.Table = unsafe { nil }
	data             strings.Builder
	text             strings.Builder
	typedefs         strings.Builder
	meta             Metadata
	literal_counter  u64
	ident_counter    u64
	indent_lvl       u8
	indent_size      u8          = 2
	loop_label_stack []LoopLabel = []
	locals           [][]Value   = [][]Value{len: 1, cap: 10, init: []Value{}}
}

struct Value {
	value string
	ty    string
}

fn (v Value) is_simple() bool {
	return v.ty in ['i1', 'i8', 'i16', 'i32', 'i64', 'float', 'double']
}

fn (v Value) str() string {
	return v.value
}

pub struct LoopLabel {
	continue_label string
	break_label    string
	name           string
}

pub fn gen(files []&ast.File, mut table ast.Table, out_name string, w_pref &pref.Preferences) {
	mut g := Gen{
		files:    files
		table:    &table
		pref:     w_pref
		is_debug: w_pref.is_debug
		data:     strings.new_builder(10 * 1024)
		text:     strings.new_builder(100 * 1024)
		typedefs: strings.new_builder(10 * 1024)
		meta:     Metadata{}
		locals:   [][]Value{len: 1, cap: 10, init: []Value{}}
	}

	// region register some builtin types
	// TODO: remove it once builtin module works
	// g.data.writeln('%string = type { ptr, i32, i32 }')
	// g.data.writeln('%array = type { ptr, i32, i32, i32, i32, i32 }')
	// g.data.writeln('')

	// g.text.witeln('
	// 	declare i32 @puts(ptr)
	// 	declare i32 @printf(ptr, ...)
	//
	// 	define void @println(%string* %s) {
	// 	start:
	// 	  %.1 = getelementptr %string, ptr %s, i32 0
	// 	  %.2 = call i32 @puts(ptr %.1)
	// 	  ret void
	// 	}'.trim_indent())
	// endregion

	g.meta.add_ident()
	g.meta.add_c_flags()

	for f in files {
		if f.is_test {
			println('Skipping test ${f.path}')
			continue
		}
		println('Processing ${f.path}')

		g.file = f

		if g.is_debug {
			g.meta.add_debug_flags()
			fidx := g.meta.add_di_file(f.path)
			flags := util.join_env_vflags_and_os_args().join(' ')
			g.meta.add_di_compile_unit(fidx, flags)
		}

		g.gen_stmts(f.stmts)
	}

	// target := '; ModuleID = \'${f.path_base}\'
	// 		|target triple = "x86_64-pc-linux-gnu"
	// 		|source_filename = "${f.path_base}"
	// 		|target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"\n\n'.strip_margin()
	target := 'target triple = "x86_64-pc-linux-gnu"
			|target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"\n\n'.strip_margin()
	all := [target, g.typedefs.str(), g.data.str(), g.text.str(),
		g.meta.str()].filter(it.len > 0).join_lines()

	if g.pref.is_verbose {
		println('---LLVM-IR---')
		println(all)
	}

	mut file := os.open_file(out_name, 'w+', 0o666) or { panic('Cannot open a file') }
	file.write_string(all) or { panic('Cannot write to file: ${err}') }
	file.flush()
	file.close()
}

fn (mut g Gen) gen_stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		g.gen_stmt(&stmt)
	}
}

fn (mut g Gen) gen_stmt(stmt &ast.Stmt) {
	match stmt {
		ast.AsmStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.AsmStmt not implemented!', stmt.pos)
		}
		ast.AssertStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.AssertStmt not implemented!', stmt.pos)
		}
		ast.AssignStmt {
			// TODO: support for a, b = b, a  and  a, b := func() needed
			if stmt.right.len > 1 || stmt.left.len > 1 {
				panic('having more than 1 expression on any side of assigment is not supported!')
			}
			right := g.gen_expr(&stmt.right[0]) or {
				panic('expression right of the assigment cannot return empty identifier!')
			}
			left := g.gen_expr(&stmt.left[0]) or {
				panic('expression left of the assigment cannot return empty identifier!')
			}
			ty := g.llvm_type_from(stmt.right_types[0])

			// :=
			if stmt.op == .decl_assign {
				// allocate
				g.w('${left} = alloca ${ty}') // TODO: add alignment ?
				g.add_local(value: left.value, ty: ty + '*')
			}
			// =
			if stmt.op in [.assign, .decl_assign] {
				g.w('store ${ty} ${right}, ptr ${left}')
				return
			}

			// // vfmt off
			// op := match stmt.op {
			// 	.plus_assign { 'add' } // +=
			// 	.minus_assign { 'sub' } // -=
			// 	.div_assign { if stmt.left_types[0].is_signed() { 'sdiv' } else { 'udiv' } } // /=
			// 	.mult_assign { 'mul' } // *=
			// 	.xor_assign { 'xor' } // ^=
			// 	.mod_assign { if stmt.left_types[0].is_signed() { 'srem' } else { 'urem' } } // %=
			// 	.or_assign { 'or' } // |=
			// 	.and_assign { 'and' } // &=
			// 	.right_shift_assign { 'sar' } // <<=
			// 	.left_shift_assign { 'shl' } // >>=
			// 	.unsigned_right_shift_assign { 'shl' } // >>>=
			// 	.boolean_and_assign { 'and' } // &&=
			// 	.boolean_or_assign { 'or' } // ||=
			// 	else {
			// 		g.show_error()c('${@FN}: ast.AssignStmt: Operator not implemented! ${stmt.op.str()}', stmt.pos)
			// 	}
			// }
			// // vfmt on
			//
			// qt := g.llvm_type_from(stmt.left_types[0])
			// g.w('${left} = ${op} ${qt} ${left}, ${right}')

			dump(stmt)
			g.show_error('${@FN}: ast.AssignStmt not implemented!', stmt.pos)
		}
		ast.Block {
			// TODO: DEBUG register DILexicalBlock if inside function and append new scope
			g.gen_stmts(stmt.stmts)
			// TODO: DEBUG remove added scope
		}
		ast.BranchStmt { // continue, break
			bp := if stmt.label != '' {
				g.loop_label_stack.filter(it.name == stmt.label).last()
			} else {
				g.loop_label_stack.last()
			}

			label := match stmt.kind {
				.key_break { bp.break_label }
				.key_continue { bp.continue_label }
				else { panic('@FN: BranchStmt: Unrecognized statement kind! | ${stmt.kind}') }
			}

			g.w('br label %${label}')
		}
		ast.ComptimeFor {
			dump(stmt)
			g.show_error('${@FN}: ast.ComptimeFor not implemented!', stmt.pos)
		}
		ast.ConstDecl {
			dump(stmt)
			g.show_error('${@FN}: ast.ConstDecl not implemented!', stmt.pos)
		}
		ast.DebuggerStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.DebuggerStmt not implemented!', stmt.pos)
		}
		ast.DeferStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.DeferStmt not implemented!', stmt.pos)
		}
		ast.EmptyStmt {} // do nothing
		ast.EnumDecl {
			// TODO: declare type in debug mode
			dump(stmt)
			g.show_error('${@FN}: ast.EnumDecl not implemented!', stmt.pos)
		}
		ast.ExprStmt {
			g.gen_expr(stmt.expr)
		}
		ast.FnDecl {
			g.gen_fn(&stmt)
		}
		ast.ForCStmt {
			g.gen_for_c(stmt)
		}
		ast.ForInStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.ForInStmt not implemented!', stmt.pos)
		}
		ast.ForStmt {
			cond := if stmt.is_inf {
				ast.Expr(ast.BoolLiteral{
					val: true
				})
			} else {
				stmt.cond
			}
			for_stmt := ast.ForCStmt{
				has_init: false
				has_cond: true
				has_inc:  false
				is_multi: false
				pos:      stmt.pos
				comments: []
				init:     ast.empty_stmt
				cond:     cond
				inc:      ast.empty_stmt
				stmts:    stmt.stmts
				label:    stmt.label
				scope:    stmt.scope
			}
			g.gen_for_c(for_stmt)
		}
		ast.GlobalDecl {
			dump(stmt)
			g.show_error('${@FN}: ast.GlobalDecl not implemented!', stmt.pos)
		}
		ast.GotoLabel {
			g.text.writeln('${stmt.name}:')
		}
		ast.GotoStmt {
			g.w('br label %${stmt.name}')
		}
		ast.HashStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.HashStmt not implemented!', stmt.pos)
		}
		ast.Import {} // ignore
		ast.InterfaceDecl {} // ignore
		ast.Module {} // ignore
		ast.NodeError {
			eprintln('${@FN}: NodeError should never be passed to gen stage! This might be a a bug. Ignoring! -> stmt: ${stmt}')
		}
		ast.Return {
			if stmt.exprs.len > 1 {
				// TODO: multi returns
				// probably would need to declare temp struct and return it
				g.show_error('${@FN}: ast.Return: Multi returns not implemented yet!',
					stmt.pos)
			} else if stmt.exprs.len == 1 {
				ident := g.gen_expr(&stmt.exprs[0]) or { panic('identifier required!') }
				g.w('ret ${ident}')
			} else {
				g.w('ret void')
			}
		}
		ast.SemicolonStmt {} // ignore
		ast.SqlStmt {
			dump(stmt)
			g.show_error('${@FN}: ast.SqlStmt not implemented!', stmt.pos)
		}
		ast.StructDecl { // TODO: unions support
			// %string = type { ptr, i32, i32 }
			field_types := stmt.fields.map(g.llvm_type_from(it.typ)).join(', ')
			name := if stmt.name.starts_with('builtin.') {
				stmt.name.all_after_last('.')
			} else {
				stmt.name
			}
			if stmt.attrs.contains('packed') {
				g.typedefs.writeln('%${name} = type <{ ${field_types} }>')
			} else {
				g.typedefs.writeln('%${name} = type { ${field_types} }')
			}
		}
		ast.TypeDecl {
			if stmt is ast.AliasTypeDecl {
				return
			}
			sym := match stmt {
				// ast.AliasTypeDecl {
				// 	// register alias for local lookup
				// 	// pub type Builder = []u8
				// 	ty := g.llvm_type_from(stmt.parent_type)
				// }
				ast.AliasTypeDecl {
					sym1 := g.table.sym(stmt.typ)
					sym2 := g.table.sym(stmt.parent_type)
					println('type: ${sym1.dbg()}')
					println('parent_type: ${sym2.dbg()}')
					// println('Alias parent dumps:')
					// for t := stmt.typ; int(t.idx) > 0; t = t.parent_idx {
					// 	sym := g.table.sym(t)
					// 	dump(sym)
					// }
					// g.table.sym(stmt.typ)
					sym2
				}
				ast.FnTypeDecl {
					g.table.sym(stmt.typ)
				}
				ast.SumTypeDecl {
					g.table.sym(stmt.typ)
				}
			}
			dump(stmt)
			println('type: ${sym.dbg()}')
			g.show_error('${@FN}: ast.TypeDecl not implemented!', stmt.pos)
		}
	}
}

fn (mut g Gen) gen_for_c(stmt ast.ForCStmt) {
	c := g.ident_counter++
	continue_label := 'FOR.${c}.CONTINUE'
	end_label := 'FOR.${c}.END'

	if stmt.has_init {
		g.w('; FOR.${c}.INIT')
		g.gen_stmt(&stmt.init)
		g.w('br label %FOR.${c}.BEGIN')
	}
	g.wwi('FOR.${c}.BEGIN:')

	// check condition
	ident := g.gen_expr(stmt.cond) or {
		panic('Condition expression in ForCStmt has to return identifier')
	}
	g.w('br i1 ${ident}, label %FOR.${c}.BLOCK, label %${end_label}')
	g.wwi('FOR.${c}.BLOCK:')
	g.loop_label_stack << LoopLabel{
		continue_label: continue_label
		break_label:    end_label
		name:           stmt.label
	}
	g.gen_stmts(stmt.stmts)
	g.loop_label_stack.pop()
	g.w('br label %${continue_label}')
	g.wwi('${continue_label}:')
	if stmt.has_inc {
		g.gen_stmt(&stmt.inc)
	}
	g.w('br label %FOR.${c}.BEGIN')
	g.wwi('${end_label}:')
}

fn (mut g Gen) gen_expr_require_ident(expr &ast.Expr) Value {
	return g.gen_expr(expr) or { panic('Expression must return a value (identifier or literal)!') }
}

fn (mut g Gen) gen_expr(expr &ast.Expr) ?Value {
	match expr {
		ast.AnonFn {
			dump(expr)
			eprintln('${g.file.path}')
			g.show_error('${@FN}: AnonFn not implemented!', expr.decl.pos)
		}
		ast.ArrayDecompose {
			// g.gen_expr(expr.expr)
			dump(expr)
			g.show_error('${@FN}: ArrayDecompose not implemented!', expr.pos)
		}
		ast.ArrayInit {
			// call __new_array_with_default_noscan
			// __new_array_with_default_noscan(mylen int, cap int, elm_size int, val voidptr)
			// Array_int a_default = __new_array_with_default_noscan(0, 0, sizeof(int), 0);
			// Array_int a_init1 = __new_array_with_default_noscan(2, 0, sizeof(int), &(int[]){1});
			// Array_int a_len = __new_array_with_default_noscan(40, 0, sizeof(int), 0);
			// Array_int a_cap = __new_array_with_default_noscan(0, 40, sizeof(int), 0);
			// Array_int a_lencap = __new_array_with_default_noscan(10, 40, sizeof(int), 0);
			// Array_int a_lencapinit1 = __new_array_with_default_noscan(10, 40, sizeof(int), &(int[]){1});
			if expr.is_fixed {
				// Array_fixed_int_5 a_fix = {0, 0, 0, 0, 0};
				// alloc len x size ???
				// TODO: fixed size arrays `[expr]Type{}`
			}
			if expr.has_val {
				// Array_int a_fix_lit = new_array_from_c_array_noscan(4, 4, sizeof(int), _MOV((int[4]){1, 2, 3, 4}));
				// TODO: fixed size literal `[expr, expr]`
			}
			ident := g.new_tmp_ident()
			len := if expr.has_len { g.gen_expr_require_ident(expr.len_expr).value } else { '0' }
			cap := if expr.has_cap { g.gen_expr_require_ident(expr.cap_expr).value } else { '0' }
			size := g.table.sym(expr.typ).size
			// TODO: make sure init is a pointer
			init := if expr.has_init { g.gen_expr_require_ident(expr.init_expr).value } else { '0' }
			// TODO: __new_array_with_default_noscan returns array struct directly or pointer to array struct ?
			g.w('${ident} = call %array @__new_array_with_default_noscan(i32 ${len}, i32 ${cap}, i32 ${size}, ptr ${init})')
			return Value{
				value: ident
				ty:    '%array'
			}
		}
		ast.AsCast {
			dump(expr)
			g.show_error('${@FN}: AsCast not implemented!', expr.pos)
		}
		ast.Assoc {
			dump(expr)
			g.w_error('${@FN}: Assoc is deprecated and wont be implemented!')
		}
		ast.AtExpr {
			dump(expr)
			g.show_error('${@FN}: AtExpr not implemented!', expr.pos)
		}
		ast.BoolLiteral {
			return Value{
				value: expr.val.str()
				ty:    'i1'
			} // true, false
		}
		ast.CTempVar {
			dump(expr)
			eprintln('${g.file.path}')
			panic('${@FN}: ast.CTempVar should be used only in cgen!')
		}
		ast.CallExpr {
			// %retval = call i32 @test(i32 %argc)
			// https://llvm.org/docs/LangRef.html#call-instruction
			mut args := expr.args.map(fn [mut g] (arg ast.CallArg) string {
				ident := g.gen_expr_require_ident(arg.expr)
				typ := g.llvm_type_from(arg.typ)
				if arg.should_be_ptr {
					return '${typ} ${ident}'
				} else {
					// dereference
					ident2 := g.new_tmp_ident()
					g.w('${ident2} = load ${typ}, ptr ${ident}')
					return '${typ} ${ident2}'
				}
			}).join(', ')

			fn_decl := if expr.is_method {
				// pass receiver as first argument
				val := g.gen_expr_require_ident(expr.left)
				typ := g.llvm_type_from(expr.receiver_type)
				args = '${typ} ${val.value}, ${args}'

				receiver := g.table.sym(expr.receiver_type)
				g.table.find_method(receiver, expr.name) or {
					g.show_error('Could not find method! | ${expr.name}', expr.pos)
				}
			} else {
				g.table.fns[expr.name] or {
					g.show_error('Could not find function! | ${expr.name}', expr.pos)
				}
			}

			ret_type := if fn_decl.is_c_variadic || fn_decl.is_variadic {
				// for variadic calls we need to use full function signature
				return_type := g.llvm_type_from(fn_decl.return_type)
				arg_types := expr.args.map(g.llvm_type_from(it.typ)).join(', ')
				'${return_type}(${arg_types})'
			} else {
				g.llvm_type_from(expr.return_type)
			}

			fn_name := if expr.language == .c { expr.name[2..] } else { expr.name }

			if expr.return_type != ast.void_type {
				// ret_type := g.llvm_type_from(expr.return_type)
				ident := g.new_tmp_ident()
				g.w('${ident} = call ${ret_type} @${fn_name}(${args})')
				return Value{
					value: ident
					ty:    g.llvm_type_from(expr.return_type)
				}
			} else {
				// ret_type == 'void' OR fn signature void(...)
				g.w('call ${ret_type} @${fn_name}(${args})')
			}
			return none
		}
		ast.CastExpr {
			if expr.has_arg {
				dump(expr)
				g.show_error('${@FN}: CastExpr with argument not implemented! | string(buf, n)',
					expr.pos)
			}
			to_type := g.table.final_type(expr.typ)
			from_type := g.table.final_type(expr.expr_type)
			// to_sym := g.table.sym(to_type)
			// from_sym := g.table.sym(from_type)

			to_size, _ := g.table.type_size(to_type)
			from_size, _ := g.table.type_size(from_type)

			// TODO: normalize rune, int, isize, etc to respective sized type
			// so it catches fi. int == i32, etc
			if g.llvm_type_from(from_type) == g.llvm_type_from(to_type)
				&& from_type.is_signed() == to_type.is_signed() {
				// no need to cast
				println('no need to cast ${g.table.type_to_str(from_type)} to ${g.table.type_to_str(to_type)}')
				return g.gen_expr(expr.expr)
			}

			// if to_sym.kind == .alias && to_sym.parent_idx == from_sym.idx {
			// 	// no need to cast if this is alias of the same type
			// 	return g.gen_expr(expr.expr)
			// }

			// if from_type.is_any_kind_of_pointer() && to_type.is_any_kind_of_pointer() {
			// 	// pointer to pointer cast is unnecessary - it is a matter of interpretation when loading values
			// 	println('no need to cast ${g.table.type_to_str(from_type)} to ${g.table.type_to_str(to_type)} - both are pointers')
			// 	return g.gen_expr(expr.expr)
			// }
			//
			if expr.expr is ast.IntegerLiteral {
				println('returning ${g.llvm_type_from(to_type)} ${expr.expr.val}')
				return Value{
					value: expr.expr.val
					ty:    g.llvm_type_from(to_type)
				}
			}

			// https://llvm.org/docs/LangRef.html#trunc-to-instruction
			if from_type.is_number() && to_type.is_number() {
				// bitcast, trunc, zext, sext

				fi := from_type.is_int()
				ti := to_type.is_int()
				ff := from_type.is_float()
				tf := to_type.is_float()

				fs := from_type.is_signed()
				ts := to_type.is_signed()

				mut op := ''
				match true {
					fi && ti && fs == ts {
						op = if from_type > to_type { 'trunc' } else { 'zext' }
					}
					fi && ti && fs != ts {
						op = 'bitcast'
					}
					ff && tf {
						// fptrunc, fpext
						op = if from_type > to_type { 'fptrunc' } else { 'fpext' }
					}
					(fi && tf) {
						// uitofp, sitofp
						op = if from_type.is_signed() {
							'sitofp'
						} else {
							'uitofp'
						}
					}
					(ff && ti) {
						// fptoui, fptosi,
						op = if to_type.is_signed() {
							'fptosi'
						} else {
							'fptoui'
						}
					}
					else {
						// dump(expr)
						g.show_error('${@FN}: CastExpr not implemented!', expr.pos)
					}
				}
				// value := if expr.expr is ast.IntegerLiteral {
				// 	// ovveride type to avoid casting
				// 	println('overriding type to avoid casting -> ${g.llvm_type_from(to_type)}')
				// 	Value{
				// 		value: expr.expr.val
				// 		ty:    g.llvm_type_from(to_type)
				// 	}
				// } else {
				// 	g.gen_expr_require_ident(expr.expr)
				// }
				value := g.gen_expr_require_ident(expr.expr)
				tmp := g.new_tmp_ident()
				g.w('${tmp} = ${op} ${value.ty} ${value.value} to ${g.llvm_type_from(to_type)}')
				println('${tmp} = ${op} ${value.ty} ${value.value} to ${g.llvm_type_from(to_type)}')
				return Value{
					value: tmp
					ty:    g.llvm_type_from(expr.typ)
				}
			}

			dump(expr)
			g.show_error('${@FN}: CastExpr not implemented!', expr.pos)
		}
		ast.ChanInit {
			dump(expr)
			g.show_error('${@FN}: ChanInit not implemented!', expr.pos)
		}
		ast.CharLiteral {
			return Value{
				value: expr.val
				ty:    'i8'
			} // TODO: does it contain escapes \n, \t ?
		}
		ast.Comment {} // ignore
		ast.ComptimeCall {
			dump(expr)
			g.show_error('${@FN}: ComptimeCall not implemented!', expr.pos)
		}
		ast.ComptimeSelector {
			dump(expr)
			g.show_error('${@FN}: ComptimeSelector not implemented!', expr.pos)
		}
		ast.ComptimeType {
			dump(expr)
			g.show_error('${@FN}: ComptimeType not implemented!', expr.pos)
		}
		ast.ConcatExpr {
			dump(expr)
			g.show_error('${@FN}: ConcatExpr not implemented!', expr.pos)
		}
		ast.DumpExpr {
			dump(expr)
			g.show_error('${@FN}: DumpExpr not implemented!', expr.pos)
		}
		ast.EmptyExpr {} // do nothing
		ast.EnumVal {
			name := g.table.sym(expr.typ).name
			value := g.table.find_enum_field_val(name, expr.val) or {
				g.w_error('Cannot find `${expr.val}` value in `${name}` enum!')
			}
			return Value{
				value: value.str()
				ty:    'i64'
			}
			// dump(expr)
			// g.show_error('${@FN}: EnumVal not implemented!', expr.pos)
		}
		ast.FloatLiteral {
			// TODO: might depend on requested type
			return Value{
				value: expr.val
				ty:    'double'
			}
			// dump(expr)
			// g.show_error('${@FN}: FloatLiteral not implemented!', expr.pos)
		}
		ast.GoExpr {
			dump(expr)
			g.show_error('${@FN}: GoExpr not implemented!', expr.pos)
		}
		ast.Ident {
			obj := expr.obj
			name := match obj {
				ast.ConstField, ast.GlobalField {
					'@' + expr.name
				}
				ast.Var {
					'%' + expr.name
				}
				ast.AsmRegister {
					g.w_error('${@FN}: AsmRegister not supported!')
				}
			}
			if expr.kind == .unresolved {
				return Value{
					value: '%' + expr.name
					ty:    '!.Unknown'
				}
			}
			value := g.find_value(name) or {
				panic('Variable, constant or global "${expr.name}" not found in scope! This is a bug.')
			}
			return value

			// // if (expr.obj is ast.Var && expr.obj.is_auto_deref) || expr.info.typ.is_string() { // not sure if string is auto_deref
			// if expr.obj is ast.Var && expr.obj.is_auto_deref { // not sure if string is auto_deref
			// 	// dereference
			// 	ident := g.new_tmp_ident()
			// 	g.w('${ident} = load %string, %string* %${expr.name}')
			// 	return ident
			// }
			// if expr.kind == .variable {
			// 	// ident := g.new_tmp_ident()
			// 	// typ := g.llvm_type_from(expr.obj.typ)
			// 	// g.w('${ident} = load ${typ}, ptr %${expr.name}')
			// 	// return ident
			// 	return '%' + expr.name
			// }
			// if expr.kind == .unresolved {
			// 	// usually argument of a function
			// 	return '%' + expr.name
			// }
			// if expr.kind == .blank_ident {
			// 	return none // Or empty ident // return g.new_tmp_ident()
			// }
			// if expr.kind in [.global, .constant] {
			// 	return '@' + expr.name
			// }
			// if expr.kind == .function {
			// 	// TODO: return ptr to function ???
			// }
			// dump(expr)
			// g.show_error()c('${@FN}: Ident not implemented expression kind! | ${expr.kind}', expr.pos)
		}
		ast.IfExpr {
			if expr.is_comptime {
				g.comptime_if_expr(expr)
				return none
				// dump(expr)
				// g.show_error()c('${@FN}: Comptime IfExpr not implemented! | \$if windows {...} ', expr.pos)
			}

			if expr.is_expr {
				// if expr.left !is ast.NodeError {
				dump(expr)
				g.show_error('${@FN}: Assign IfExpr not implemented! | a := if true {...}',
					expr.pos)
			}

			c := g.literal_counter++

			for nr, branch in expr.branches {
				if branch.cond !is ast.NodeError {
					// we have condition to check
					g.w('; IF.${c}.${nr} condition')
					cond := g.gen_expr_require_ident(branch.cond)
					// br i1 %cond, label %IfEqual, label %IfUnequal
					g.w('br i1 ${cond}, label %IF.${c}.${nr}.TRUE, label %IF.${c}.${nr}.FALSE')
					g.wwi('IF.${c}.${nr}.TRUE:')
					g.gen_stmts(branch.stmts)
					g.w('br label %IF.${c}.END')
					g.wwi('IF.${c}.${nr}.FALSE:')
				} else {
					// else branch
					g.gen_stmts(branch.stmts)
					g.w('br label %IF.${c}.END')
				}
			}
			g.wwi('IF.${c}.END:')
		}
		ast.IfGuardExpr {
			dump(expr)
			eprintln('${g.file.path}')
			pos := token.Pos{
				line_nr: expr.vars[0].pos.line_nr
				col:     0
				len:     3
			}
			g.show_error('${@FN}: IfGuardExpr not implemented! | if x := opt() {...}',
				pos)
		}
		ast.IndexExpr {
			dump(expr)
			g.show_error('${@FN}: IndexExpr not implemented!', expr.pos)
		}
		ast.InfixExpr {
			k := expr.op
			f := expr.left_type.is_float()
			s := expr.left_type.is_signed()

			// vfmt off
			op := match true {
				k == .plus && !f 	  { 'add'  }
				k == .plus && f 	  { 'fadd' }
				k == .minus && !f     { 'sub'  }
				k == .minus && f      { 'fsub' }
				k == .mod && f        { 'frem' }
				k == .mod && !f && s  { 'srem' }
			    k == .mod && !f && !s { 'urem' }
				k == .mul && !f       { 'mul'  }
				k == .mul && f        { 'fmul' }
				k == .div && f        { 'fdiv' }
				k == .div && !f && s  { 'sdiv' }
				k == .div && !f && !s { 'udiv' }

				k == .eq && !f       { 'icmp eq' }
				k == .ne && !f       { 'icmp ne' }

				k == .gt && !f && s  { 'icmp sgt' }
				k == .lt && !f && s  { 'icmp slt' }
				k == .ge && !f && s  { 'icmp sge' }
				k == .le && !f && s  { 'icmp sle' }

				k == .gt && !f && !s { 'icmp ugt' }
				k == .lt && !f && !s { 'icmp ult' }
				k == .ge && !f && !s { 'icmp uge' }
				k == .le && !f && !s { 'icmp ule' }

				// https://llvm.org/docs/LangRef.html#fcmp-instruction
				// TODO: unordered or ordered for floating comparisons ?
				// for now use ordered
				k == .eq && f { 'fcmp oeq' }
				k == .ne && f { 'fcmp one' }
				k == .gt && f { 'fcmp ogt' }
				k == .lt && f { 'fcmp olt' }
				k == .ge && f { 'fcmp oge' }
				k == .le && f { 'fcmp ole' }


				// k == .key_in {}
				// k == .key_as {}
				// k == .logical_or { 'or' }
				// k == .xor { 'xor' }
				// k == .not_in {}
				// k == .key_is {}
				// k == .not_is {}
				// k == .and { 'and' }
				// k == .dot {}
				// k == .pipe {}
				// k == .amp {} // if expr.right.is_auto_deref_var() { -- dereference (load) -- }
				// k == .left_shift { 'shl' }
				// k == .right_shift { 'sar'}
				// k == .unsigned_right_shift { 'shr' }
				// k == .arrow {} // channel <- value // pushes value to a channel
				// k == .key_like {}
				// k == .key_ilike {}
				else {
					dump(expr)
					eprintln('${g.file.path}:${expr.pos.line_nr+1}:${expr.pos.col}')
					panic("gen_expr: InfixExpr: Operand not Implemented! | ${expr.op.str()}")
				}
			}
			// vfmt on
			left_val := g.gen_expr(expr.left) or {
				panic('Expected identifier on left side of ${expr.op.str()}')
			}
			right_val := g.gen_expr(expr.right) or {
				panic('Expected identifier on right side of ${expr.op.str()}')
			}

			left_ty := g.llvm_type_from(expr.left_type)
			// right_ty := g.llvm_type_from(expr.right_type)

			ident := g.new_tmp_ident()
			left := g.load(left_val)
			right := g.load(right_val)
			g.w('${ident} = ${op} ${left_ty} ${left}, ${right}')
			return Value{
				value: ident
				ty:    left_ty
			}
		}
		ast.IntegerLiteral {
			// TODO: might depend on requested type
			return Value{
				value: expr.val
				ty:    'i64'
			}
		}
		ast.IsRefType {
			dump(expr)
			g.show_error('${@FN}: IsRefType not implemented!', expr.pos)
		}
		ast.LambdaExpr {
			dump(expr)
			g.show_error('${@FN}: LambdaExpr not implemented!', expr.pos)
		}
		ast.Likely {
			dump(expr)
			g.show_error('${@FN}: Likely not implemented!', expr.pos)
		}
		ast.LockExpr {
			dump(expr)
			g.show_error('${@FN}: LockExpr not implemented!', expr.pos)
		}
		ast.MapInit {
			dump(expr)
			g.show_error('${@FN}: MapInit not implemented!', expr.pos)
		}
		ast.MatchExpr {
			dump(expr)
			g.show_error('${@FN}: MatchExpr not implemented!', expr.pos)
		}
		ast.Nil {
			// return 0
			dump(expr)
			g.show_error('${@FN}: Nil not implemented!', expr.pos)
		}
		ast.NodeError {
			dump(expr)
			g.show_error('${@FN}: NodeError should not be present at gen stage! This ia a bug!',
				expr.pos)
		}
		ast.None {
			dump(expr)
			g.show_error('${@FN}: None not implemented!', expr.pos)
		}
		ast.OffsetOf {
			dump(expr)
			g.show_error('${@FN}: OffsetOf not implemented!', expr.pos)
		}
		ast.OrExpr {
			dump(expr)
			g.show_error('${@FN}: OrExpr not implemented!', expr.pos)
		}
		ast.ParExpr {
			return g.gen_expr(expr.expr)
		}
		ast.PostfixExpr { // a++, a--
			child_ident := g.gen_expr_require_ident(expr.expr)
			ty := g.llvm_type_from(expr.typ)
			mut op := match expr.op {
				.inc { 'add' }
				.dec { 'sub' }
				else { g.w_error('${@FN}: ast.PostfixExpr: Operand not Implemented! | ${expr.op.str()}') }
			}

			if expr.typ.is_float() {
				op = 'f' + op
			}

			ident1 := g.load(child_ident)
			ident2 := g.new_tmp_ident()
			g.w('${ident2} = ${op} ${ty} ${ident1}, 1')
			g.w('store ${ty} ${ident2}, ptr ${child_ident}')

			return child_ident
		}
		ast.PrefixExpr {
			match expr.op {
				.mul { // *ident
					// dereference
					child_ident := g.gen_expr_require_ident(expr.right)
					ty := g.llvm_type_from(expr.right_type)
					ident := g.new_tmp_ident()
					g.w('${ident} = load ${ty}, ptr ${child_ident}')
					return Value{
						value: ident
						ty:    ty
					}
				}
				else {
					dump(expr)
					g.show_error('${@FN}: PrefixExpr not implemented for ${expr.op.str()}!',
						expr.pos)
				}
			}
		}
		ast.RangeExpr {
			dump(expr)
			g.show_error('${@FN}: RangeExpr not implemented!', expr.pos)
		}
		ast.SelectExpr {
			dump(expr)
			g.show_error('${@FN}: SelectExpr not implemented!', expr.pos)
		}
		ast.SelectorExpr {
			unaliased_type := g.table.unaliased_type(expr.expr_type)
			symbol := g.table.sym(unaliased_type)
			kind := symbol.kind
			match kind {
				.struct, .string {
					struct_info := symbol.struct_info()
					field := struct_info.get_field(expr.field_name)
					pure_typ := g.llvm_type_from(unaliased_type).trim_right('*')
					field_ty := g.llvm_type_from(field.typ)
					ptr := g.gen_expr_require_ident(expr.expr)
					// ident1 := g.new_tmp_ident()
					ident2 := g.new_tmp_ident()
					//%q = getelementptr %MyStruct, ptr %p, i64 %idx, i32 1, i32 1
					// g.w('${ident1} = load ${pure_typ}*, ${pure_typ}** ${ptr}')
					// g.w('${ident2} = extractvalue ${field_ty} ${ident1}, ${field.i}')
					g.w('${ident2} = getelementptr inbounds ${pure_typ}, ptr ${ptr}, i32 0, i32 ${field.i}')
					return Value{
						value: ident2
						ty:    field_ty
					}
				}
				.array {
					// TODO: check if this is correct
					return g.gen_expr_require_ident(expr.expr)
				}
				else {
					dump(expr)
					g.show_error('${@FN}: SelectorExpr not implemented for ${kind}!',
						expr.pos)
				}
			}
		}
		ast.SizeOf {
			dump(expr)
			g.show_error('${@FN}: SizeOf not implemented!', expr.pos)
		}
		ast.SpawnExpr {
			dump(expr)
			g.show_error('${@FN}: SpawnExpr not implemented!', expr.pos)
		}
		ast.SqlExpr {
			dump(expr)
			g.show_error('${@FN}: SqlExpr not implemented!', expr.pos)
		}
		ast.StringInterLiteral {
			dump(expr)
			g.show_error('${@FN}: StringInterLiteral not implemented!', expr.pos)
		}
		ast.StringLiteral {
			// @.strlit1_raw = private unnamed_addr constant [12 x i8] c"hello world\00"
			// @.strlit1 = private unnamed_addr constant %string { ptr @.strlit1_raw, i32 11, i32 1 }
			ident := g.new_strlit_ident()

			str, len := if expr.is_raw {
				expr.val, expr.val.len
			} else {
				// TODO: escape string - f.i. \n, \t, etc - to hexadecimal \0A, \09
				// TODO: escape \xx strings ???
				// TODO: validate c escape sequences
				mut escaped_str := expr.val.replace(r'\\', r'\5C')
				escaped_str = escaped_str.replace(r'\0', r'\00')
				escaped_str = escaped_str.replace(r'\n', r'\0A')
				escaped_str = escaped_str.replace(r'\r', r'\0D')
				escaped_str = escaped_str.replace(r'\t', r'\09')
				escaped_str = escaped_str.replace("\\'", r'\27')
				escaped_str = escaped_str.replace('\\"', r'\22')
				// hex values \x## -> \##
				escaped_str = escaped_str.replace(r'\x', r'\')
				// TODO: octal to hex \### -> \##
				// TODO: utf8 to individual hex bytes - ★ \u2605 -> \E2\98\85

				// count the length of the string
				len := escaped_str.len - (escaped_str.count(r'\') * 2)
				escaped_str, len
			}
			g.data.writeln('${ident}_raw = private unnamed_addr constant [${len + 1} x i8] c"${str}\\00"')
			g.data.writeln('${ident} = private unnamed_addr constant %string { ptr ${ident}_raw, i32 ${len}, i32 1 }')
			return Value{
				value: ident
				ty:    '%string*'
			}
		}
		ast.StructInit {
			dump(expr)
			g.show_error('${@FN}: StructInit not implemented!', expr.pos)
		}
		ast.TypeNode {
			dump(expr)
			g.show_error('${@FN}: TypeNode not implemented!', expr.pos)
		}
		ast.TypeOf {
			dump(expr)
			g.show_error('${@FN}: TypeOf not implemented!', expr.pos)
		}
		ast.UnsafeExpr {
			return g.gen_expr(expr.expr)
		}
	}
	return none
}

fn (mut g Gen) new_strlit_ident() string {
	g.literal_counter++
	return '@.strlit${g.literal_counter}'
}

fn (mut g Gen) new_tmp_ident() string {
	g.ident_counter++
	return '%.${g.ident_counter}'
}

fn (mut g Gen) llvm_type_from(t ast.Type) string {
	if t.is_any_kind_of_pointer() {
		return 'ptr'
	}

	sym := g.table.sym(t)
	match sym.kind {
		.alias {
			type_info := sym.info as ast.Alias
			typ := type_info.parent_type
			return g.llvm_type_from(typ)
		}
		.enum {
			return g.llvm_type_from(sym.enum_info().typ)
		}
		.array {
			// since array does not care about underlying type
			// we can straight away return pointer to array struct
			return '%array*'
		}
		.array_fixed {
			info := sym.array_fixed_info()
			ty := g.llvm_type_from(info.elem_type)
			size := info.size
			return '[${size} x ${ty}]'
		}
		// .map {}
		// .chan {}
		.struct {
			return '%' + sym.name + '*'
		}
		else {}
	}

	// If this is array of c types - f.i. []VoidPtr (used in vararg)
	// Should not catch normal V arrays
	// if t.idx() != ast.array_type_idx && sym.kind == .array {
	// 	info := sym.array_info()
	// 	internal_type := g.llvm_type_from(info.elem_type)
	// 	return '[${internal_type}]'
	// }

	// vfmt off
	return match t.idx() {
		ast.bool_type_idx { 'i1' }
		ast.i8_type_idx,
		ast.u8_type_idx,
		ast.char_type_idx { 'i8' }
		ast.i16_type_idx,
		ast.u16_type_idx { 'i16' }
		ast.i32_type_idx,
		ast.u32_type_idx,
		ast.rune_type_idx,
		ast.int_type_idx { 'i32' }
		ast.i64_type_idx,
		ast.u64_type_idx,
		ast.int_literal_type_idx { 'i64' }
		ast.f32_type_idx { 'float' }
		ast.float_literal_type_idx,
		ast.f64_type_idx { 'double' }
		ast.isize_type_idx,
		ast.usize_type_idx { if g.pref.m64 { 'i64' } else { 'i32' } } // TODO: check if other architectures should be supported
		ast.string_type_idx { '%string*' }
		ast.array_type_idx { '%array*' }
		// ast.map_type_idx { '%map*' }
		// ast.chan_type_idx { '%chan*' }
		ast.void_type { 'void' }
		else {
			println("type: ${sym.dbg()}")
			panic('${@FN}: unknown type: ${g.table.type_str(t)}')
		}
	}
	// vfmt on
}

fn (mut g Gen) gen_fn(stmt &ast.FnDecl) {
	if stmt.should_be_skipped {
		return
	}

	ret_type := g.llvm_type_from(stmt.return_type)

	if stmt.language == .c && stmt.no_body {
		param_types := if stmt.is_variadic || stmt.is_variadic {
			stmt.params#[..-1].map(g.llvm_type_from(it.typ)).join(', ') + ', ...'
		} else {
			stmt.params.map(g.llvm_type_from(it.typ)).join(', ')
		}
		g.w('declare ${ret_type} @${stmt.short_name}(${param_types})\n')
		return
	}

	fn_name := if stmt.is_main { 'main' } else { stmt.name }

	g.text.write_string('define ')
	g.text.write_string(ret_type)
	g.text.write_string(' \@')
	g.text.write_string(fn_name)
	if stmt.params.len > 0 {
		g.text.write_string('(')
		for i, param in stmt.params {
			g.text.write_string('${g.llvm_type_from(param.typ)} %p${i}, ')
		}
		g.text.go_back(2)
		g.text.write_string(')')
	} else {
		g.text.write_string('()')
	}
	if g.is_debug {
		idx := g.meta.add_di_subprogram(stmt, fn_name, stmt.pos.line_nr, stmt.pos.line_nr,
			g.meta.add('!{}'))
		g.text.write_string(' !dbg !')
		g.text.write_decimal(idx)
	}
	g.text.write_string(' {\nentry:\n')

	g.add_scope()

	g.indent_lvl++
	for i, param in stmt.params {
		ty := g.llvm_type_from(param.typ)
		g.w('%${param.name} = alloca ${ty}')
		g.w('store ${ty} %p${i}, ptr %${param.name}')
		g.add_local(Value{ value: '%${param.name}', ty: ty })
	}
	g.gen_stmts(stmt.stmts)
	if !stmt.has_return {
		g.w('ret void')
	}
	g.indent_lvl--
	if g.is_debug {
		g.meta.di_scope.pop()
	}

	g.remove_scope()

	g.wwi('}\n')
}

fn (mut g Gen) add_scope() {
	g.locals << []Value{}
}

fn (mut g Gen) remove_scope() {
	g.locals.pop()
}

fn (mut g Gen) find_value(name string) ?Value {
	for i := g.locals.len - 1; i >= 0; i-- {
		for j := 0; j < g.locals[i].len; j++ {
			if g.locals[i][j].value == name {
				return g.locals[i][j]
			}
		}
	}
	return none
}

fn (mut g Gen) add_local(value Value) {
	if g.locals.len > 0 {
		g.locals[g.locals.len - 1] << value
	} else {
		g.locals << [value]
	}
}

fn (mut g Gen) load(v Value) string {
	if v.is_simple() {
		return v.value
	}
	if v.ty.ends_with('*') {
		ident := g.new_tmp_ident()
		ty := v.ty.all_before_last('*')
		g.w('${ident} = load ${ty}, ptr ${v.value}')
		return ident
	}
	panic('Not a simple value nor pointer ... What kind of value is it ? | ${v}')
}

// w Writes line to text buffer with indent
@[inline]
fn (mut g Gen) w(line string) {
	len := int(g.indent_lvl) * int(g.indent_size)
	indent := strings.repeat(' '[0], len)
	g.text.write_string(indent)
	g.text.writeln(line)
}

// wwi Write Without Indent - Writes line to text buffer without indent
@[inline]
fn (mut g Gen) wwi(line string) {
	g.text.writeln(line)
}

@[noreturn]
pub fn (mut g Gen) w_error(s string) {
	if g.pref.is_verbose {
		print_backtrace()
	}
	util.verror('llvm error', s)
}

@[noreturn]
pub fn (g Gen) show_error(msg string, p token.Pos) {
	eprintln('\n${g.file.path}:${p.line_nr + 1}:${p.col} ${msg}\n')

	lines := os.read_lines(g.file.path) or { panic('Could not read file ${g.file.path}!') }

	low := math.max(p.line_nr - 3, 0)
	high := math.min(p.line_nr + 4, lines.len)

	for i in low .. high {
		if i < 0 || i >= lines.len {
			continue
		}
		line := lines[i]
		if i == p.line_nr {
			eprintln(term.ecolorize(term.red, '${i + 1:5}| ${line}'))
			eprintln(term.ecolorize(term.red, '${strings.repeat_string(' ', p.col + 7)}${strings.repeat_string('^',
				p.len)}'))
		} else {
			eprintln('${i + 1:5}| ${line}')
		}
	}
	eprintln('')
	panic(msg)
}
