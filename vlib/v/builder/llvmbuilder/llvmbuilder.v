module llvmbuilder

import os
import v.builder
import v.pref
import v.util
import v.gen.llvm

@[params]
pub struct StartParams {
pub:
	prefs &pref.Preferences = unsafe { nil }
}

pub fn start(params StartParams) {
	mut prefs := params.prefs
	if params.prefs == unsafe { nil } {
		mut args_and_flags := util.join_env_vflags_and_os_args()[1..]
		prefs, _ = pref.parse_args_and_show_errors([], args_and_flags, false)
	}
	builder.compile('build', prefs, compile_llvm)
}

pub fn compile_llvm(mut b builder.Builder) {
	mut files := b.get_builtin_files()
	files << b.get_user_files()
	b.set_module_lookup_paths()
	if b.pref.is_verbose {
		println('all .v files:')
		println(files)
	}
	out_name := b.pref.out_name

	// TODO: replace latter with get_vtmp_filename below
	vtmp := os.vtmp_dir()
	fname := os.file_name(os.real_path(out_name)) + '.tmp.ll'
	out_name_ll := os.real_path(os.join_path(vtmp, fname))
	// out_name_ll := b.get_vtmp_filename(b.pref.out_name, '.tmp.ssa')
	// out_name_bc := out_name_ll#[..-3] + 'bc'
	build_llvm(mut b, files, out_name_ll)
	if !os.exists_in_system_path('clang-18') {
		eprintln('clang-18 executable not found in PATH!')
		return
	}
	// res_cc := os.execute('cc -g -Lc ${out_name_s} -o ${out_name}')
	res_cc := os.execute('clang-18 -g -O0 ${out_name_ll} -o ${out_name}')
	if res_cc.exit_code != 0 {
		eprintln(res_cc.output)
		exit(res_cc.exit_code)
	}
}

pub fn build_llvm(mut b builder.Builder, v_files []string, out_file string) {
	b.front_and_middle_stages(v_files) or { return }
	util.timing_start('LLVM GEN')
	llvm.gen(b.parsed_files, mut b.table, out_file, b.pref)
	util.timing_measure('LLVM GEN')
}
