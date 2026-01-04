use inkwell::{
    types::BasicType,
    values::{IntValue, PointerValue},
};
use roc_mono::layout::{LayoutRepr, STLayoutInterner};
use roc_target::Target;

use super::{align::LlvmAlignment, build::Env, convert::basic_type_from_layout};

pub fn build_memcpy<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout: LayoutRepr<'a>,
    destination: PointerValue<'ctx>,
    source: PointerValue<'ctx>,
) {
    let align_bytes = layout.llvm_alignment_bytes(layout_interner);
    let width = basic_type_from_layout(env, layout_interner, layout)
        .size_of()
        .unwrap();
    if align_bytes > 0 {
        // There is actually something to memcpy.
        // For SBF targets, use regular memcpy function call instead of llvm.memcpy.inline
        // because the inline intrinsic requires immediate (constant) sizes.
        if matches!(env.target, Target::Sbf) {
            // Call memcpy function directly for SBF
            build_memcpy_call(env, destination, source, width);
        } else {
            env.builder
                .build_memcpy(destination, align_bytes, source, align_bytes, width)
                .unwrap();
        }
    }
}

/// Build a call to memcpy function instead of using the inline intrinsic.
/// This is needed for SBF targets where llvm.memcpy.inline doesn't work with variable sizes.
fn build_memcpy_call<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    destination: PointerValue<'ctx>,
    source: PointerValue<'ctx>,
    size: IntValue<'ctx>,
) {
    let i8_ptr_type = env.context.ptr_type(inkwell::AddressSpace::default());
    let i64_type = env.context.i64_type();

    // Get or declare memcpy function
    let memcpy_fn = match env.module.get_function("memcpy") {
        Some(f) => f,
        None => {
            let fn_type = i8_ptr_type.fn_type(
                &[i8_ptr_type.into(), i8_ptr_type.into(), i64_type.into()],
                false,
            );
            env.module.add_function("memcpy", fn_type, None)
        }
    };

    // Convert size to i64 if needed
    let size_i64 = env
        .builder
        .build_int_z_extend_or_bit_cast(size, i64_type, "size_i64")
        .unwrap();

    env.builder
        .build_call(
            memcpy_fn,
            &[destination.into(), source.into(), size_i64.into()],
            "memcpy_call",
        )
        .unwrap();
}

/// Build memcpy with raw size and alignment parameters.
/// This is a drop-in replacement for builder.build_memcpy() that handles SBF targets correctly.
/// For SBF, it uses a regular memcpy function call instead of llvm.memcpy.inline intrinsic.
pub fn build_memcpy_raw<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    destination: PointerValue<'ctx>,
    dest_align: u32,
    source: PointerValue<'ctx>,
    src_align: u32,
    size: IntValue<'ctx>,
) {
    // For SBF targets, use regular memcpy function call instead of llvm.memcpy.inline
    // because the inline intrinsic requires immediate (constant) sizes.
    if matches!(env.target, Target::Sbf) {
        build_memcpy_call(env, destination, source, size);
    } else {
        env.builder
            .build_memcpy(destination, dest_align, source, src_align, size)
            .unwrap();
    }
}
