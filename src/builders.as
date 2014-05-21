import llvm;
import libc;
import types;
import generator_;
import code;
import ast;
import list;
import errors;
import generator_util;
import generator_def;
import builder;
import resolver;
import resolvers;

# Builders
# =============================================================================

# Identifier [TAG_IDENT]
# -----------------------------------------------------------------------------
def ident(g: ^mut generator_.Generator, node: ^ast.Node,
          scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Retrieve the item with scope resolution rules.
    let id: ^ast.Ident = (node^).unwrap() as ^ast.Ident;
    let item: ^code.Handle = generator_util.get_scoped_item_in(
        g^, id.name.data() as str, scope, g.ns);

    # Return the item.
    item;
}

# Boolean [TAG_BOOLEAN]
# -----------------------------------------------------------------------------
def boolean(g: ^mut generator_.Generator, node: ^ast.Node,
            scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.BooleanExpr = (node^).unwrap() as ^ast.BooleanExpr;

    # Build a llvm val for the boolean expression.
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMConstInt(llvm.LLVMInt1Type(), (1 if x.value else 0), false);

    # Wrap and return the value.
    code.make_value(target, val);
}

# Integer [TAG_INTEGER]
# -----------------------------------------------------------------------------
def integer(g: ^mut generator_.Generator, node: ^ast.Node,
            scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.IntegerExpr = (node^).unwrap() as ^ast.IntegerExpr;

    # Get the type handle from the target.
    let typ: ^code.Type = target._object as ^code.Type;

    # Build a llvm val for the boolean expression.
    let val: ^llvm.LLVMOpaqueValue;
    if target._tag == code.TAG_INT_TYPE
    {
        val = llvm.LLVMConstIntOfString(
            typ.handle, x.text.data(), x.base as uint8);
    }
    else
    {
        val = llvm.LLVMConstRealOfString(typ.handle, x.text.data());
    }

    # Wrap and return the value.
    code.make_value(target, val);
}

# Floating-point [TAG_FLOAT]
# -----------------------------------------------------------------------------
def float(g: ^mut generator_.Generator, node: ^ast.Node,
          scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.FloatExpr = (node^).unwrap() as ^ast.FloatExpr;

    # Get the type handle from the target.
    let typ: ^code.Type = target._object as ^code.Type;

    # Build a llvm val for the boolean expression.
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMConstRealOfString(typ.handle, x.text.data());

    # Wrap and return the value.
    code.make_value(target, val);
}

# Local Slot [TAG_LOCAL_SLOT]
# -----------------------------------------------------------------------------
def local_slot(g: ^mut generator_.Generator, node: ^ast.Node,
               scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.LocalSlotDecl = (node^).unwrap() as ^ast.LocalSlotDecl;

    # Get the name out of the node.
    let id: ^ast.Ident = x.id.unwrap() as ^ast.Ident;

    # Get and resolve the type node (if we have one).
    let type_han: ^code.Handle = code.make_nil();
    let type_: ^code.Type = 0 as ^code.Type;
    if not ast.isnull(x.type_) {
        type_han = resolver.resolve(g, &x.type_);
        type_ = type_han._object as ^code.Type;
    }

    # Get and resolve the initializer (if we have one).
    let init: ^llvm.LLVMOpaqueValue = 0 as ^llvm.LLVMOpaqueValue;
    if not ast.isnull(x.initializer) {
        # Resolve the type of the initializer.
        let typ: ^code.Handle;
        typ = resolver.resolve_st(g, &x.initializer, scope, type_han);
        if code.isnil(typ) { return code.make_nil(); }

        # Check and set
        if code.isnil(type_han) {
            type_han = typ;
            type_ = type_han._object as ^code.Type;
        }

        # Build the initializer
        let han: ^code.Handle;
        han = builder.build(g, &x.initializer, scope, typ);
        if code.isnil(han) { return code.make_nil(); }

        # Cast it to the target value.
        let cast_han: ^code.Handle = generator_util.cast(g^, han, type_han);

        # Coerce this to a value.
        let val_han: ^code.Handle = generator_def.to_value(
            g^, cast_han, false);
        let val: ^code.Value = val_han._object as ^code.Value;
        init = val.handle;
    }

    # Build a stack allocation.
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMBuildAlloca(g.irb, type_.handle, id.name.data());

    # Build the store.
    if init <> 0 as ^llvm.LLVMOpaqueValue {
        llvm.LLVMBuildStore(g.irb, init, val);
    }

    # Wrap.
    let han: ^code.Handle;
    han = code.make_local_slot(type_han, x.mutable, val);

    # Insert into the current local scope block.
    (scope^).insert(id.name.data() as str, han);

    # Return.
    han;
}

# Call [TAG_CALL]
# -----------------------------------------------------------------------------
def call_function(g: ^mut generator_.Generator, node: ^ast.CallExpr,
                  scope: ^mut code.Scope,
                  x: ^code.Function,
                  type_: ^code.FunctionType) -> ^code.Handle
{
    # First we create and zero a list to hold the entire argument list.
    let mut argl: list.List = list.make(types.PTR);
    argl.reserve(type_.parameters.size);
    argl.size = type_.parameters.size;
    libc.memset(argl.elements as ^void, 0, (argl.size * argl.element_size) as int32);
    let argv: ^mut ^llvm.LLVMOpaqueValue =
        argl.elements as ^^llvm.LLVMOpaqueValue;

    # Iterate through each argument, build, and push them into
    # their appropriate position in the argument list.
    let mut i: int = 0;
    while i as uint < node.arguments.size()
    {
        # Get the specific argument.
        let anode: ast.Node = node.arguments.get(i);
        i = i + 1;
        let a: ^ast.Argument = anode.unwrap() as ^ast.Argument;

        # Find the parameter index.
        # NOTE: The parser handles making sure no positional arg
        #   comes after a keyword arg.
        let mut param_idx: uint = 0;
        if ast.isnull(a.name)
        {
            # An unnamed argument just corresponds to the sequence.
            param_idx = i as uint - 1;
        }
        else
        {
            # Get the name data for the id.
            let id: ^ast.Ident = a.name.unwrap() as ^ast.Ident;

            # Check for the existance of this argument.
            if not type_.parameter_map.contains(id.name.data() as str)
            {
                errors.begin_error();
                errors.fprintf(errors.stderr,
                               "unexpected keyword argument '%s'" as ^int8,
                               id.name.data());
                errors.end();
                return code.make_nil();
            }

            # Check if we already have one of these.
            if (argv + param_idx)^ <> 0 as ^llvm.LLVMOpaqueValue {
                errors.begin_error();
                errors.fprintf(errors.stderr,
                               "got multiple values for argument '%s'" as ^int8,
                               id.name.data());
                errors.end();
                return code.make_nil();
            }

            # Pull the named argument index.
            param_idx = type_.parameter_map.get_uint(id.name.data() as str);
        }

        # Resolve the type of the argument expression.
        let typ: ^code.Handle = resolver.resolve_st(
            g, &a.expression, scope,
            code.type_of(type_.parameters.at_ptr(param_idx as int) as ^code.Handle));
        if code.isnil(typ) { return code.make_nil(); }

        # Build the argument expression node.
        let han: ^code.Handle = builder.build(g, &a.expression, scope, typ);
        if code.isnil(han) { return code.make_nil(); }

        # Coerce this to a value.
        let val_han: ^code.Handle = generator_def.to_value(g^, han, false);

        # Cast the value to the target type.
        let cast_han: ^code.Handle = generator_util.cast(g^, val_han, typ);
        let cast_val: ^code.Value = cast_han._object as ^code.Value;

        # Emplace in the argument list.
        (argv + param_idx)^ = cast_val.handle;

        # Dispose.
        code.dispose(val_han);
        code.dispose(cast_han);
    }

    # Check for missing arguments.
    i = 0;
    let mut error: bool = false;
    while i as uint < argl.size {
        let arg: ^llvm.LLVMOpaqueValue = (argv + i)^;
        if arg == 0 as ^llvm.LLVMOpaqueValue
        {
            # Get formal name
            let prm_han: ^code.Handle =
                type_.parameters.at_ptr(i) as ^code.Handle;
            let prm: ^code.Parameter =
                prm_han._object as ^code.Parameter;

            # Report
            errors.begin_error();
            errors.fprintf(errors.stderr,
                           "missing required parameter '%s'" as ^int8,
                           prm.name.data());
            errors.end();
            error = true;
        }

        i = i + 1;
    }
    if error { return code.make_nil(); }

    # Build the `call` instruction.
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMBuildCall(
        g.irb, x.handle, argv, argl.size as uint32, "" as ^int8);

    # Dispose of dynamic memory.
    argl.dispose();

    if code.isnil(type_.return_type) {
        # Return nil.
        code.make_nil();
    } else {
        # Wrap and return the value.
        code.make_value(type_.return_type, val);
    }
}

def call_default_ctor(g: ^mut generator_.Generator, node: ^ast.CallExpr,
                      scope: ^mut code.Scope,
                      x: ^code.Struct,
                      type_: ^code.StructType) -> ^code.Handle
{
    # We need to create a constant value of our structure type.

    # First we create and zero a list to hold the entire argument list.
    let mut argl: list.List = list.make(types.PTR);
    argl.reserve(type_.members.size);
    argl.size = type_.members.size;
    libc.memset(argl.elements as ^void, 0, (argl.size * argl.element_size) as int32);
    let argv: ^mut ^llvm.LLVMOpaqueValue =
        argl.elements as ^^llvm.LLVMOpaqueValue;

    # Iterate through each argument, build, and push them into
    # their appropriate position in the argument list.
    let mut i: int = 0;
    while i as uint < node.arguments.size()
    {
        # Get the specific argument.
        let anode: ast.Node = node.arguments.get(i);
        i = i + 1;
        let a: ^ast.Argument = anode.unwrap() as ^ast.Argument;

        # Find the parameter index.
        # NOTE: The parser handles making sure no positional arg
        #   comes after a keyword arg.
        let mut param_idx: uint = 0;
        if ast.isnull(a.name)
        {
            # An unnamed argument just corresponds to the sequence.
            param_idx = i as uint - 1;
        }
        else
        {
            # Get the name data for the id.
            let id: ^ast.Ident = a.name.unwrap() as ^ast.Ident;

            # Check for the existance of this argument.
            if not type_.member_map.contains(id.name.data() as str)
            {
                errors.begin_error();
                errors.fprintf(errors.stderr,
                               "unexpected keyword argument '%s'" as ^int8,
                               id.name.data());
                errors.end();
                return code.make_nil();
            }

            # Check if we already have one of these.
            if (argv + param_idx)^ <> 0 as ^llvm.LLVMOpaqueValue {
                errors.begin_error();
                errors.fprintf(errors.stderr,
                               "got multiple values for argument '%s'" as ^int8,
                               id.name.data());
                errors.end();
                return code.make_nil();
            }

            # Pull the named argument index.
            param_idx = type_.member_map.get_uint(id.name.data() as str);
        }

        # Resolve the type of the argument expression.
        let typ: ^code.Handle = resolver.resolve_st(
            g, &a.expression, scope,
            code.type_of(type_.members.at_ptr(param_idx as int) as ^code.Handle));
        if code.isnil(typ) { return code.make_nil(); }

        # Build the argument expression node.
        let han: ^code.Handle = builder.build(g, &a.expression, scope, typ);
        if code.isnil(han) { return code.make_nil(); }

        # Coerce this to a value.
        let val_han: ^code.Handle = generator_def.to_value(g^, han, false);

        # Cast the value to the target type.
        let cast_han: ^code.Handle = generator_util.cast(g^, val_han, typ);
        let cast_val: ^code.Value = cast_han._object as ^code.Value;

        # Emplace in the argument list.
        (argv + param_idx)^ = cast_val.handle;

        # Dispose.
        code.dispose(val_han);
        code.dispose(cast_han);
    }

    # Check for missing arguments.
    i = 0;
    let mut error: bool = false;
    while i as uint < argl.size {
        let arg: ^llvm.LLVMOpaqueValue = (argv + i)^;
        if arg == 0 as ^llvm.LLVMOpaqueValue
        {
            # Get formal name
            let prm_han: ^code.Handle =
                type_.members.at_ptr(i) as ^code.Handle;
            let prm: ^code.Member =
                prm_han._object as ^code.Member;

            # Report
            errors.begin_error();
            errors.fprintf(errors.stderr,
                           "missing required parameter '%s'" as ^int8,
                           prm.name.data());
            errors.end();
            error = true;
        }

        i = i + 1;
    }
    if error { return code.make_nil(); }

    # Build the "call" instruction (and create the constant struct).
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMConstNamedStruct(type_.handle, argv, argl.size as uint32);

    # let val: ^llvm.LLVMOpaqueValue;
    # val = llvm.LLVMBuildCall(
    #     g.irb, x.handle, argv, argl.size as uint32, "" as ^int8);

    # Dispose of dynamic memory.
    argl.dispose();

    # Wrap and return the value.
    code.make_value(x.type_, val);
}

def call(g: ^mut generator_.Generator, node: ^ast.Node,
         scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.CallExpr = (node^).unwrap() as ^ast.CallExpr;

    # Build the called expression.
    let expr: ^code.Handle = builder.build(
        g, &x.expression, scope, code.make_nil());
    if code.isnil(expr) { return code.make_nil(); }

    # Pull out the handle and its type.
    if expr._tag == code.TAG_FUNCTION
    {
        let type_: ^code.FunctionType;
        let fn_han: ^code.Function = expr._object as ^code.Function;
        type_ = fn_han.type_._object as ^code.FunctionType;
        return call_function(g, x, scope, fn_han, type_);
    }
    else if expr._tag == code.TAG_STRUCT
    {
        let type_: ^code.StructType;
        let han: ^code.Struct = expr._object as ^code.Struct;
        type_ = han.type_._object as ^code.StructType;
        return call_default_ctor(g, x, scope, han, type_);
    }

    # No idea how to handle this (shouldn't be able to get here).
    code.make_nil();
}

# Binary arithmetic
# -----------------------------------------------------------------------------
def arithmetic_b_operands(g: ^mut generator_.Generator, node: ^ast.Node,
                          scope: ^mut code.Scope, target: ^code.Handle)
    -> (^code.Handle, ^code.Handle)
{
    let res: (^code.Handle, ^code.Handle) = (code.make_nil(), code.make_nil());

    # Unwrap the node to its proper type.
    let x: ^ast.BinaryExpr = (node^).unwrap() as ^ast.BinaryExpr;

    # Resolve each operand for its type.
    let lhs_ty: ^code.Handle = resolver.resolve_st(g, &x.lhs, scope, target);
    let rhs_ty: ^code.Handle = resolver.resolve_st(g, &x.rhs, scope, target);

    # Build each operand.
    let lhs: ^code.Handle = builder.build(g, &x.lhs, scope, lhs_ty);
    let rhs: ^code.Handle = builder.build(g, &x.rhs, scope, rhs_ty);
    if code.isnil(lhs) or code.isnil(rhs) { return res; }

    # Coerce the operands to values.
    let lhs_val_han: ^code.Handle = generator_def.to_value(g^, lhs, false);
    let rhs_val_han: ^code.Handle = generator_def.to_value(g^, rhs, false);
    if code.isnil(lhs_val_han) or code.isnil(rhs_val_han) { return res; }

    # Create a tuple result.
    res = (lhs_val_han, rhs_val_han);
    res;
}

# Relational [TAG_EQ, TAG_NE, TAG_LT, TAG_LE, TAG_GT, TAG_GE]
# -----------------------------------------------------------------------------
def relational(g: ^mut generator_.Generator, node: ^ast.Node,
               scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.BinaryExpr = (node^).unwrap() as ^ast.BinaryExpr;

    # Build each operand.
    let lhs_val_han: ^code.Handle;
    let rhs_val_han: ^code.Handle;
    (lhs_val_han, rhs_val_han) = arithmetic_b_operands(
        g, node, scope, code.make_nil());
    if code.isnil(lhs_val_han) or code.isnil(rhs_val_han) {
        # Return nil.
        return code.make_nil();
    }

    # Resolve our type.
    let type_: ^code.Handle = resolvers.type_common(
        &x.lhs,
        code.type_of(lhs_val_han),
        &x.rhs,
        code.type_of(rhs_val_han));
    if code.isnil(type_) {
        # Return nil.
        return code.make_nil();
    }

    # Cast each operand to the target type.
    let lhs_han: ^code.Handle = generator_util.cast(g^, lhs_val_han, type_);
    let rhs_han: ^code.Handle = generator_util.cast(g^, rhs_val_han, type_);

    # Cast to values.
    let lhs_val: ^code.Value = lhs_han._object as ^code.Value;
    let rhs_val: ^code.Value = rhs_han._object as ^code.Value;

    # Build the comparison instruction.
    let val: ^llvm.LLVMOpaqueValue;
    if type_._tag == code.TAG_INT_TYPE
            or type_._tag == code.TAG_BOOL_TYPE {
        # Get the comparison opcode to use.
        let mut opc: int32 = -1;
        if      node.tag == ast.TAG_EQ { opc = 32; }
        else if node.tag == ast.TAG_NE { opc = 33; }
        else if node.tag == ast.TAG_GT { opc = 34; }
        else if node.tag == ast.TAG_GE { opc = 35; }
        else if node.tag == ast.TAG_LT { opc = 36; }
        else if node.tag == ast.TAG_LE { opc = 37; }

        # Switch to signed if neccessary.
        if node.tag <> ast.TAG_EQ and node.tag <> ast.TAG_NE {
            let typ: ^code.IntegerType = type_._object as ^code.IntegerType;
            if typ.signed {
                opc = opc + 4;
            }
        }

        # Build the `ICMP` instruction.
        val = llvm.LLVMBuildICmp(
            g.irb,
            opc,
            lhs_val.handle, rhs_val.handle, "" as ^int8);
    } else if type_._tag == code.TAG_FLOAT_TYPE {
        # Get the comparison opcode to use.
        let mut opc: int32 = -1;
        if      node.tag == ast.TAG_EQ { opc = 1; }
        else if node.tag == ast.TAG_NE { opc = 6; }
        else if node.tag == ast.TAG_GT { opc = 2; }
        else if node.tag == ast.TAG_GE { opc = 3; }
        else if node.tag == ast.TAG_LT { opc = 4; }
        else if node.tag == ast.TAG_LE { opc = 5; }

        # Build the `FCMP` instruction.
        val = llvm.LLVMBuildFCmp(
            g.irb,
            opc,
            lhs_val.handle, rhs_val.handle, "" as ^int8);
    }

    # Wrap and return the value.
    let han: ^code.Handle;
    han = code.make_value(target, val);

    # Dispose.
    code.dispose(lhs_val_han);
    code.dispose(rhs_val_han);
    code.dispose(lhs_han);
    code.dispose(rhs_han);

    # Return our wrapped result.
    han;
}

# Unary Arithmetic [TAG_PROMOTE, TAG_NUMERIC_NEGATE, TAG_LOGICAL_NEGATE,
#                   TAG_BITNEG]
# -----------------------------------------------------------------------------
def arithmetic_u(g: ^mut generator_.Generator, node: ^ast.Node,
                 scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.UnaryExpr = (node^).unwrap() as ^ast.UnaryExpr;

    # Resolve the operand for its type.
    let operand_ty: ^code.Handle = resolver.resolve_st(
        g, &x.operand, scope, target);

    # Build each operand.
    let operand_ty_han: ^code.Type = operand_ty._object as ^code.Type;
    let operand: ^code.Handle = builder.build(
        g, &x.operand, scope, operand_ty);
    if code.isnil(operand) { return code.make_nil(); }

    # Coerce the operands to values.
    let operand_val_han: ^code.Handle = generator_def.to_value(
        g^, operand, false);
    if code.isnil(operand_val_han) { return code.make_nil(); }

    # Cast to values.
    let operand_val: ^code.Value = operand_val_han._object as ^code.Value;

    # Build the instruction.
    let val: ^llvm.LLVMOpaqueValue = operand_val.handle;
    if target._tag == code.TAG_INT_TYPE {
        # Build the correct operation.
        if node.tag == ast.TAG_NUMERIC_NEGATE {
            # Build the `NEG` instruction.
            val = llvm.LLVMBuildNeg(
                g.irb,
                operand_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_BITNEG {
            # Build the `NOT` instruction.
            val = llvm.LLVMBuildNot(
                g.irb,
                operand_val.handle, "" as ^int8);
        }
    } else if target._tag == code.TAG_FLOAT_TYPE {
        # Build the correct operation.
        if node.tag == ast.TAG_NUMERIC_NEGATE {
            # Build the `NEG` instruction.
            val = llvm.LLVMBuildNeg(
                g.irb,
                operand_val.handle, "" as ^int8);
        }
    } else if target._tag == code.TAG_BOOL_TYPE {
        # Build the correct operation.
        if node.tag == ast.TAG_BITNEG or node.tag == ast.TAG_LOGICAL_NEGATE {
            # Build the `NOT` instruction.
            val = llvm.LLVMBuildNot(
                g.irb,
                operand_val.handle, "" as ^int8);
        }
    }

    # Wrap and return the value.
    let han: ^code.Handle;
    han = code.make_value(target, val);

    # Dispose.
    code.dispose(operand_val_han);

    # Return our wrapped result.
    han;
}

# Binary Arithmetic [TAG_ADD, TAG_SUBTRACT, TAG_MULTIPLY,
#                    TAG_DIVIDE, TAG_MODULO]
# -----------------------------------------------------------------------------
def arithmetic_b(g: ^mut generator_.Generator, node: ^ast.Node,
                 scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.BinaryExpr = (node^).unwrap() as ^ast.BinaryExpr;

    # Build each operand.
    let lhs_val_han: ^code.Handle;
    let rhs_val_han: ^code.Handle;
    (lhs_val_han, rhs_val_han) = arithmetic_b_operands(
        g, node, scope, code.make_nil());
    if code.isnil(lhs_val_han) or code.isnil(rhs_val_han) {
        # Return nil.
        return code.make_nil();
    }

    # Cast each operand to the target type.
    let lhs_han: ^code.Handle = generator_util.cast(g^, lhs_val_han, target);
    let rhs_han: ^code.Handle = generator_util.cast(g^, rhs_val_han, target);

    # Cast to values.
    let lhs_val: ^code.Value = lhs_han._object as ^code.Value;
    let rhs_val: ^code.Value = rhs_han._object as ^code.Value;

    # Build the instruction.
    let val: ^llvm.LLVMOpaqueValue;
    if target._tag == code.TAG_INT_TYPE {
        # Get the internal type.
        let typ: ^code.IntegerType = target._object as ^code.IntegerType;

        # Build the correct operation.
        if node.tag == ast.TAG_ADD {
            # Build the `ADD` instruction.
            val = llvm.LLVMBuildAdd(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_SUBTRACT {
            # Build the `SUB` instruction.
            val = llvm.LLVMBuildSub(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_MULTIPLY {
            # Build the `MUL` instruction.
            val = llvm.LLVMBuildMul(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_DIVIDE or node.tag == ast.TAG_INTEGER_DIVIDE {
            # Build the `DIV` instruction.
            if typ.signed {
                val = llvm.LLVMBuildSDiv(
                    g.irb,
                    lhs_val.handle, rhs_val.handle, "" as ^int8);
            } else {
                val = llvm.LLVMBuildUDiv(
                    g.irb,
                    lhs_val.handle, rhs_val.handle, "" as ^int8);
            }
        } else if node.tag == ast.TAG_MODULO {
            # Build the `MOD` instruction.
            if typ.signed {
                val = llvm.LLVMBuildSRem(
                    g.irb,
                    lhs_val.handle, rhs_val.handle, "" as ^int8);
            } else {
                val = llvm.LLVMBuildURem(
                    g.irb,
                    lhs_val.handle, rhs_val.handle, "" as ^int8);
            }
        } else if node.tag == ast.TAG_BITAND {
            # Build the `AND` instruction.
            val = llvm.LLVMBuildAnd(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_BITOR {
            # Build the `OR` instruction.
            val = llvm.LLVMBuildOr(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_BITXOR {
            # Build the `XOR` instruction.
            val = llvm.LLVMBuildXor(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        }
    } else if target._tag == code.TAG_FLOAT_TYPE {
        # Build the correct operation.
        if node.tag == ast.TAG_ADD {
            # Build the `ADD` instruction.
            val = llvm.LLVMBuildFAdd(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_SUBTRACT {
            # Build the `SUB` instruction.
            val = llvm.LLVMBuildFSub(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_MULTIPLY {
            # Build the `MUL` instruction.
            val = llvm.LLVMBuildFMul(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_DIVIDE or node.tag == ast.TAG_INTEGER_DIVIDE {
            # Build the `DIV` instruction.
            val = llvm.LLVMBuildFDiv(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        } else if node.tag == ast.TAG_MODULO {
            # Build the `MOD` instruction.
            val = llvm.LLVMBuildFRem(
                g.irb,
                lhs_val.handle, rhs_val.handle, "" as ^int8);
        }
    }

    # Wrap and return the value.
    let han: ^code.Handle;
    han = code.make_value(target, val);

    # Dispose.
    code.dispose(lhs_val_han);
    code.dispose(rhs_val_han);
    code.dispose(lhs_han);
    code.dispose(rhs_han);

    # Return our wrapped result.
    han;
}

# Integer Divide [TAG_INTEGER_DIVIDE]
# -----------------------------------------------------------------------------
def integer_divide(g: ^mut generator_.Generator, node: ^ast.Node,
                   scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Perform a normal division.
    let han: ^code.Handle;
    han = arithmetic_b(g, node, scope, target);

    # FIXME: Perform a `floor` on the result.

    # Return the result.
    han;
}

# Return [TAG_RETURN]
# -----------------------------------------------------------------------------
def return_(g: ^mut generator_.Generator, node: ^ast.Node,
            scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the "ploymorphic" node to its proper type.
    let x: ^ast.ReturnExpr = (node^).unwrap() as ^ast.ReturnExpr;

    # Generate a handle for the expression (if we have one.)
    if not ast.isnull(x.expression) {
        let expr: ^code.Handle = builder.build(
            g, &x.expression, scope, target);
        if code.isnil(expr) { return code.make_nil(); }

        # Coerce the expression to a value.
        let val_han: ^code.Handle = generator_def.to_value(g^, expr, false);
        let val: ^code.Value = val_han._object as ^code.Value;

        # Create the `RET` instruction.
        llvm.LLVMBuildRet(g.irb, val.handle);

        # Dispose.
        code.dispose(expr);
        code.dispose(val_han);
    } else {
        # Create the void `RET` instruction.
        llvm.LLVMBuildRetVoid(g.irb);
        void;  #HACK
    }

    # Nothing is forwarded from a `return`.
    code.make_nil();
}

# Assignment [TAG_ASSIGN]
# -----------------------------------------------------------------------------
def assign(g: ^mut generator_.Generator, node: ^ast.Node,
           scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the "ploymorphic" node to its proper type.
    let x: ^ast.BinaryExpr = (node^).unwrap() as ^ast.BinaryExpr;

    # Resolve each operand for its type.
    let lhs_ty: ^code.Handle = resolver.resolve_st(g, &x.lhs, scope, target);
    let rhs_ty: ^code.Handle = resolver.resolve_st(g, &x.rhs, scope, target);
    if code.isnil(lhs_ty) or code.isnil(rhs_ty) { return code.make_nil(); }

    # Build each operand.
    let lhs: ^code.Handle = builder.build(g, &x.lhs, scope, lhs_ty);
    let rhs: ^code.Handle = builder.build(g, &x.rhs, scope, rhs_ty);
    if code.isnil(lhs) or code.isnil(rhs) { return code.make_nil(); }

    # Coerce the operand to its value.
    let rhs_val_han: ^code.Handle = generator_def.to_value(g^, rhs, false);
    if code.isnil(rhs_val_han) { return code.make_nil(); }

    # Cast the operand to the target type.
    let rhs_han: ^code.Handle = generator_util.cast(g^, rhs_val_han, target);

    # Cast to a value.
    let rhs_val: ^code.Value = rhs_han._object as ^code.Value;

    # Perform the assignment (based on what we have in the LHS).
    if lhs._tag == code.TAG_STATIC_SLOT {
        # Get the real object.
        let slot: ^code.StaticSlot = lhs._object as ^code.StaticSlot;

        # Ensure that we are mutable.
        if not slot.context.mutable {
            # Report error and return nil.
            errors.begin_error();
            errors.fprintf(errors.stderr,
                           "cannot assign to immutable static item" as ^int8);
            errors.end();
            return code.make_nil();
        }

        # Build the `STORE` operation.
        llvm.LLVMBuildStore(g.irb, rhs_val.handle, slot.handle);
    } else if lhs._tag == code.TAG_LOCAL_SLOT {
        # Get the real object.
        let slot: ^code.LocalSlot = lhs._object as ^code.LocalSlot;

        # Ensure that we are mutable.
        if not slot.mutable {
            # Report error and return nil.
            errors.begin_error();
            errors.fprintf(errors.stderr,
                           "re-assignment to immutable local slot" as ^int8);
            errors.end();
            return code.make_nil();
        }

        # Build the `STORE` operation.
        llvm.LLVMBuildStore(g.irb, rhs_val.handle, slot.handle);
    } else {
        # Report error and return nil.
        errors.begin_error();
        errors.fprintf(errors.stderr,
                       "left-hand side expression is not assignable" as ^int8);
        errors.end();
        return code.make_nil();
    }

    # Dispose.
    code.dispose(rhs_val_han);
    code.dispose(rhs_han);

    # Return the RHS.
    rhs;
}

# Conditional Expression [TAG_CONDITIONAL]
# -----------------------------------------------------------------------------
def conditional(g: ^mut generator_.Generator, node: ^ast.Node,
                scope: ^code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.ConditionalExpr = (node^).unwrap() as ^ast.ConditionalExpr;

    # Build the condition.
    let cond_han: ^code.Handle;
    cond_han = builder.build(
        g, &x.condition, scope, g.items.get_ptr("bool") as ^code.Handle);
    if code.isnil(cond_han) { return code.make_nil(); }
    let cond_val_han: ^code.Handle = generator_def.to_value(
        (g^), cond_han, false);
    let cond_val: ^code.Value = cond_val_han._object as ^code.Value;
    if code.isnil(cond_val_han) { return code.make_nil(); }

    # Get the current basic block and resolve our current function handle.
    let cur_block: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMGetInsertBlock(g.irb);
    let cur_fn: ^llvm.LLVMOpaqueValue = llvm.LLVMGetBasicBlockParent(
        cur_block);

    # Create the three neccessary basic blocks: then, else, merge.
    let then_b: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMAppendBasicBlock(
        cur_fn, "" as ^int8);
    let else_b: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMAppendBasicBlock(
        cur_fn, "" as ^int8);
    let merge_b: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMAppendBasicBlock(
        cur_fn, "" as ^int8);

    # Create the conditional branch.
    llvm.LLVMBuildCondBr(g.irb, cond_val.handle, then_b, else_b);

    # Switch to the `then` block.
    llvm.LLVMPositionBuilderAtEnd(g.irb, then_b);

    # Build the `lhs` operand.
    let lhs: ^code.Handle = builder.build(g, &x.lhs, scope, target);
    if code.isnil(lhs) { return code.make_nil(); }
    let lhs_val_han: ^code.Handle = generator_def.to_value(g^, lhs, false);
    if code.isnil(lhs_val_han) { return code.make_nil(); }
    let lhs_han: ^code.Handle = generator_util.cast(g^, lhs_val_han, target);
    let lhs_val: ^code.Value = lhs_han._object as ^code.Value;

    # Add an unconditional branch to the `merge` block.
    llvm.LLVMBuildBr(g.irb, merge_b);

    # Switch to the `else` block.
    llvm.LLVMPositionBuilderAtEnd(g.irb, else_b);

    # Build the `rhs` operand.
    let rhs: ^code.Handle = builder.build(g, &x.rhs, scope ,target);
    if code.isnil(rhs) { return code.make_nil(); }
    let rhs_val_han: ^code.Handle = generator_def.to_value(g^, rhs, false);
    if code.isnil(rhs_val_han) { return code.make_nil(); }
    let rhs_han: ^code.Handle = generator_util.cast(g^, rhs_val_han, target);
    let rhs_val: ^code.Value = rhs_han._object as ^code.Value;

    # Add an unconditional branch to the `merge` block.
    llvm.LLVMBuildBr(g.irb, merge_b);

    # Switch to the `merge` block.
    llvm.LLVMPositionBuilderAtEnd(g.irb, merge_b);

    # Create a `PHI` node.
    let type_han: ^code.Type = target._object as ^code.Type;
    let val: ^llvm.LLVMOpaqueValue;
    val = llvm.LLVMBuildPhi(g.irb, type_han.handle, "" as ^int8);
    llvm.LLVMAddIncoming(val, &lhs_val.handle, &then_b, 1);
    llvm.LLVMAddIncoming(val, &rhs_val.handle, &else_b, 1);

    # Wrap and return the value.
    let han: ^code.Handle;
    han = code.make_value(target, val);

    # Dispose.
    code.dispose(lhs_val_han);
    code.dispose(rhs_val_han);
    code.dispose(lhs_han);
    code.dispose(rhs_han);

    # Return our wrapped result.
    han;
}

# Block
# -----------------------------------------------------------------------------
def block(g: ^mut generator_.Generator, node: ^ast.Node,
          scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.Block = (node^).unwrap() as ^ast.Block;

    # Build each node in the branch.
    let mut j: int = 0;
    let mut res: ^code.Handle = code.make_nil();
    while j as uint < x.nodes.size() {
        # Resolve this node.
        let n: ast.Node = x.nodes.get(j);
        j = j + 1;

        # Resolve the type of the node.
        let cur_count: uint = errors.count;
        let typ: ^code.Handle = resolver.resolve_st(
            g, &n, scope, target);
        if cur_count < errors.count { continue; }

        # Build the node.
        let han: ^code.Handle = builder.build(g, &n, scope, typ);
        if not code.isnil(han) {
            if j as uint == x.nodes.size() {
                let val_han: ^code.Handle = generator_def.to_value(
                    g^, han, false);
                res = val_han;
            }
        }
    }

    # Return the final result.
    res;
}

# Selection [TAG_SELECT]
# -----------------------------------------------------------------------------
def select(g: ^mut generator_.Generator, node: ^ast.Node,
           scope: ^mut code.Scope, target: ^code.Handle) -> ^code.Handle
{
    # Unwrap the node to its proper type.
    let x: ^ast.SelectExpr = (node^).unwrap() as ^ast.SelectExpr;
    let has_value: bool = target._tag <> code.TAG_VOID_TYPE;

    # Get the type target for each node.
    let type_target: ^code.Handle = target;
    if type_target._tag == code.TAG_VOID_TYPE {
        type_target = code.make_nil();
    }

    # Get the current basic block and resolve our current function handle.
    let cur_block: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMGetInsertBlock(g.irb);
    let cur_fn: ^llvm.LLVMOpaqueValue = llvm.LLVMGetBasicBlockParent(
        cur_block);

    # Iterate through each branch in the select statement.
    # Generate each if/elif block chain until we get to the last branch.
    let mut i: int = 0;
    let mut values: list.List = list.make(types.PTR);
    let mut blocks: list.List = list.make(types.PTR);
    let bool_ty: ^code.Handle = g.items.get_ptr("bool") as ^code.Handle;
    while i as uint < x.branches.size() {
        let brn: ast.Node = x.branches.get(i);
        let br: ^ast.SelectBranch = brn.unwrap() as ^ast.SelectBranch;
        let blk_node: ast.Node = br.block;
        let blk: ^ast.Block = blk_node.unwrap() as ^ast.Block;

        # The last branch (else) is signaled by having no condition.
        if ast.isnull(br.condition) { break; }

        # Build the condition.
        let cond_han: ^code.Handle;
        cond_han = builder.build(g, &br.condition, scope, bool_ty);
        if code.isnil(cond_han) { return code.make_nil(); }
        let cond_val_han: ^code.Handle = generator_def.to_value(
            g^, cond_han, false);
        let cond_val: ^code.Value = cond_val_han._object as ^code.Value;
        if code.isnil(cond_val_han) { return code.make_nil(); }

        # Create and append the `then` block.
        let then_b: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMAppendBasicBlock(
            cur_fn, "" as ^int8);

        # Create a `next` block.
        let next_b: ^llvm.LLVMOpaqueBasicBlock = llvm.LLVMAppendBasicBlock(
            cur_fn, "" as ^int8);

        # Insert the `conditional branch` for this branch.
        llvm.LLVMBuildCondBr(g.irb, cond_val.handle, then_b, next_b);

        # Switch to the `then` block.
        llvm.LLVMPositionBuilderAtEnd(g.irb, then_b);

        # Build each node in the branch.
        let blk_val_han: ^code.Handle = block(g, &blk_node, scope, type_target);

        # If we are expecting a value ...
        if has_value {
            # Cast the block value to our target type.
            let val_han: ^code.Handle = generator_def.to_value(
                g^, blk_val_han, false);
            let cast_han: ^code.Handle = generator_util.cast(
                g^, val_han, type_target);
            let val: ^code.Value = cast_han._object as ^code.Value;

            # Update our value list.
            values.push_ptr(val.handle as ^void);
        }

        # Update the branch list.
        blocks.push_ptr(llvm.LLVMGetInsertBlock(g.irb) as ^void);

        # Insert the `next` block after our current block.
        llvm.LLVMMoveBasicBlockAfter(next_b, llvm.LLVMGetInsertBlock(g.irb));

        # Replace the outer-block with our new "merge" block.
        llvm.LLVMPositionBuilderAtEnd(g.irb, next_b);

        # Increment branch iterator.
        i = i + 1;
    }

    # Use the last elided block for our final "else" block.
    let merge_b: ^llvm.LLVMOpaqueBasicBlock;
    if i as uint < x.branches.size() {
        let brn: ast.Node = x.branches.get(-1);
        let br: ^ast.SelectBranch = brn.unwrap() as ^ast.SelectBranch;

        # Build each node in the branch.
        let blk_val_han: ^code.Handle = block(
            g, &br.block, scope, type_target);

        # If we are expecting a value ...
        if has_value {
            # Cast the block value to our target type.
            let val_han: ^code.Handle = generator_def.to_value(
                g^, blk_val_han, false);
            let cast_han: ^code.Handle = generator_util.cast(
                g^, val_han, type_target);
            let val: ^code.Value = cast_han._object as ^code.Value;

            # Update our value list.
            values.push_ptr(val.handle as ^void);
        }

        # Update the branch list.
        blocks.push_ptr(llvm.LLVMGetInsertBlock(g.irb) as ^void);

        # Create the last "merge" block.
        merge_b = llvm.LLVMAppendBasicBlock(cur_fn, "" as ^int8);
    } else {
        # There is no else block; use it as a merge block.
        merge_b = llvm.LLVMGetLastBasicBlock(cur_fn);
    }

    # Iterate through the established branches and have them return to
    # the "merge" block (if they are not otherwise terminated).
    i = 0;
    while i as uint < blocks.size {
        let bb: ^llvm.LLVMOpaqueBasicBlock =
            blocks.at_ptr(i) as ^llvm.LLVMOpaqueBasicBlock;
        i = i + 1;

        # Set the insertion point.
        llvm.LLVMPositionBuilderAtEnd(g.irb, bb);

        # Insert the non-conditional branch.
        llvm.LLVMBuildBr(g.irb, merge_b);
    }

    # Re-establish our insertion point.
    llvm.LLVMPositionBuilderAtEnd(g.irb, merge_b);

    if values.size > 0 {
        # Insert the PHI node corresponding to the built values.
        let type_han: ^code.Type = type_target._object as ^code.Type;
        let val: ^llvm.LLVMOpaqueValue;
        val = llvm.LLVMBuildPhi(g.irb, type_han.handle, "" as ^int8);
        llvm.LLVMAddIncoming(
            val,
            values.elements as ^^llvm.LLVMOpaqueValue,
            blocks.elements as ^^llvm.LLVMOpaqueBasicBlock,
            values.size as uint32);

        # Wrap and return the value.
        let han: ^code.Handle;
        han = code.make_value(type_target, val);

        # Dispose.
        blocks.dispose();
        values.dispose();

        # Wrap and return the PHI.
        han;
    } else {
        # Dispose.
        blocks.dispose();
        values.dispose();

        # Return nil.
        code.make_nil();
    }
}
