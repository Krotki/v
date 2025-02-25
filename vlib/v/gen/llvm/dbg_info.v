module llvm

import os
import crypto.md5
import encoding.hex
import v.util.version
import strings
import arrays
import v.ast

struct MDString {
	data string
}

fn (s MDString) str() string {
	if s.data.is_ascii() {
		return '!"' + s.data + '"'
	} else {
		mut b := strings.new_builder(s.data.len + 64)
		b.write_string('!"')
		for c in s.data.bytes() {
			if c > u8(` `) && c < u8(`~`) {
				b.write_u8(c)
			} else if c <= 127 {
				b.write_u8(u8(`\\`))
				b.write_string(c.hex().to_upper())
			}
		}
		b.write_string('"')
		return b.str()
	}
}

type MDAny = MDNode | MDString | MDIndex

struct MDNode {
	data []string
}

fn (n MDNode) str() string {
	return '!{' + n.data.join(', ') + '}'
}

struct Metadata {
mut:
	cu       MDIndex
	ident    MDIndex
	flags    []MDIndex
	data     []string
	di_scope []MDIndex // stack of scope indexes, DIFile first, DISubprogram, ...etc
}

fn (mut m Metadata) add(entry string) MDIndex {
	index := m.data.len
	m.data << entry
	return MDIndex(u64(index))
}

fn (mut m Metadata) add_debug_flags() {
	m.flags << m.add(r'!{i32 7, !"Dwarf Version", i32 5}')
	m.flags << m.add(r'!{i32 2, !"Debug Info Version", i32 3}')
}

fn (mut m Metadata) add_c_flags() {
	m.flags << m.add('!{i32 1, !"wchar_size", i32 4}')
	m.flags << m.add('!{i32 8, !"PIC Level", i32 2}')
	m.flags << m.add('!{i32 7, !"PIE Level", i32 2}')
	m.flags << m.add('!{i32 7, !"uwtable", i32 2}')
	m.flags << m.add('!{i32 7, !"frame-pointer", i32 2}')
}

fn (mut m Metadata) add_ident() {
	idx := m.add('!{!"${version.full_v_version(false)}"}')
	m.ident = idx
}

// metadata index
type MDIndex = u64

fn (i MDIndex) str() string {
	return '!' + u64(i).str()
}

fn (mut m Metadata) add_di_file(file string) MDIndex {
	bytes := os.read_bytes(file) or { panic(err) }
	md5sum := hex.encode(md5.sum(bytes))

	// !DIFile(filename: "path/to/file", directory: "/path/to/dir", checksumkind: CSK_MD5, checksum: "000102030405060708090a0b0c0d0e0f")
	// !DIFile(filename: "path/to/file", directory: "/path/to/dir")
	idx := m.add('!DIFile(filename: "${file}", directory: "${os.dir(file)}", checksumkind: CSK_MD5, checksum: "${md5sum}")')
	m.di_scope << idx
	return idx
}

fn (mut m Metadata) add_di_compile_unit(di_file_index MDIndex, flags string) MDIndex {
	// distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "Ubuntu clang version 14.0.0-1ubuntu1.1", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: None)
	// distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "Ubuntu clang version 18.1.8 (++20240731024944+3b5b5c1ec4a3-1~exp1~20240731145000.144)", isOptimized: false, flags: "/usr/lib/llvm-18/bin/clang -g -S -emit-llvm adder_ptr.c -o adder_ptr.ll", runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: None)
	v_version := version.full_v_version(false)
	idx := m.add('distinct !DICompileUnit(language: DW_LANG_C11, file: ${di_file_index}, producer: "${v_version}", flags: "${flags}", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: None)')
	m.cu = idx
	return idx
}

fn (mut m Metadata) add_di_subprogram(func ast.FnDecl, name string, line int, scopeLine int, retainedNodes MDIndex) MDIndex {
	// distinct !DISubprogram(name: "add", scope: !1, file: !1, line: 5, type: !11, scopeLine: 5, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0, retainedNodes: !15)
	file := m.di_scope.first()
	scope := m.di_scope.last()
	// TODO: C declarations should have different flags

	idx := m.add('distinct !DISubprogram(name: "${name}", scope: ${scope}, file: ${file}, line: ${line}, type: !11, scopeLine: ${scopeLine}, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: ${m.cu}, retainedNodes: ${retainedNodes})')
	m.di_scope << idx
	return idx
}

fn (m Metadata) str() string {
	cu := '!llvm.dbg.cu = !{${m.cu}}'
	ident := '!llvm.ident = !{${m.ident}}'
	flags := if m.flags.len > 0 {
		f := m.flags.map(it.str()).join(', ')
		'!llvm.module.flags = !{${f}}'
	} else {
		''
	}
	meta := arrays.map_indexed(m.data, fn (i int, line string) string {
		return '!${i} = ${line}'
	}).join_lines()

	return [ident, flags, cu, meta].filter(!it.is_blank()).join_lines()
}
