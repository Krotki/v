module builtin

pub struct string {
pub:
	str &u8 = 0
	len int
mut:
	is_lit int
}

fn C.puts(msg charptr) int

pub fn println(s string) {
	C.puts(s.str)
}

pub fn C.printf(const_format charptr, opt ...voidptr) int
