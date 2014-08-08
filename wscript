# -*- coding: utf-8 -*-
import sys
import ws.test
import ws.snapshot
import waflib.Scripting
from os import path
import shutil
from subprocess import Popen, PIPE
from glob import glob


top = '.'
out = 'build'

VERSION = "0.1.0"
SNAPSHOT_VERSION = "0.1.0"


def distclean(ctx):
    try:
        # Wipe the `.cache` dir.
        shutil.rmtree(path.join(top, ".cache"))

    except FileNotFoundError:
        # I think this is the point.
        pass

    # Clean the rest of the files.
    waflib.Scripting.distclean(ctx)


def options(ctx):
    # Add an option to specify an existing arrow compiler for the boostrap
    # process.
    ctx.add_option("--with-arrow", action='store', dest='arrow')

    # Add a --with-llvm-config option to specify what binary to use here
    # instead of the standard `llvm-config`.
    ctx.add_option(
        '--with-llvm-config', action='store', default='llvm-config',
        dest='llvm_config')


def configure(ctx):
    # Load preconfigured tools.
    ctx.load('c_config')

    # Ensure that we receive a path to an existing arrow compiler.
    if not ctx.options.arrow:
        # Attempt to get a snapshot for this platform.
        try:
            ctx.env.ARROW_SNAPSHOT = ws.snapshot.get_snapshot(SNAPSHOT_VERSION)

        except ws.snapshot.SnapshotNotFound:
            ctx.fatal("An existing arrow compiler is needed for the "
                      "boostrap process; specify one with \"--with-arrow\"")
    else:
        ctx.env.ARROW_SNAPSHOT = ctx.options.arrow

    # Report the compiler to be used.
    ctx.msg("Checking for 'arrow' (Arrow compiler)", ctx.env.ARROW_SNAPSHOT)

    # Check for the llvm compiler.
    ctx.find_program('llc', var='LLC')
    ctx.find_program('lli', var='LLI')
    ctx.find_program('opt', var='OPT')

    # Check for gcc.
    # NOTE: We only depend on this for the linking phase.
    ctx.find_program('gcc', var='GCC')
    ctx.find_program('g++', var='GXX')

    # Check for the LLVM libraries.
    ctx.check_cfg(path=ctx.options.llvm_config, package='',
                  args='--ldflags --libs all', uselib_store='LLVM')


def build(ctx):

    # Build the stage-0 compiler from the fetched snapshot
    # Compile the compiler from llvm IL into native object code.
    ctx(rule="${LLC} -filetype=obj -o=${TGT} ${ARROW_SNAPSHOT}",
        target="stage0/arrow.o")

    # Link the compiler into a final executable.
    libs = " ".join(map(lambda x: "-l%s" % x, ctx.env['LIB_LLVM']))
    ctx(rule="${GXX} -o${TGT} ${SRC} %s" % libs,
        source="stage0/arrow.o",
        target="stage0/arrow",
        name="stage0")

    # Take the stage-1 compiler (the one that we have through
    # reasons unknown to us). Use this to compile the stage-2 compiler.

    # Compile the compiler to the llvm IL.
    ctx(rule="../build/stage0/arrow ${SRC} | ${OPT} -O3 -o=../build/${TGT}",
        source="src/compiler.as",
        target="stage1/arrow.ll",
        cwd="src",
        after="stage0")

    # Compile the compiler from llvm IL into native object code.
    ctx(rule="${LLC} -filetype=obj -o=${TGT} ${SRC}",
        source="stage1/arrow.ll",
        target="stage1/arrow.o")

    # Link the compiler into a final executable.
    libs = " ".join(map(lambda x: "-l%s" % x, ctx.env['LIB_LLVM']))
    ctx(rule="${GXX} -o${TGT} ${SRC} %s" % libs,
        source="stage1/arrow.o",
        target="stage1/arrow",
        name="stage1")

    # TODO: Run the test suite on the stage-2 compiler

    # Use the newly compiled stage-1 to compile the stage-2 compiler

    # Compile the compiler to the llvm IL.
    ctx(rule="../build/stage1/arrow ${SRC} | ${OPT} -O3 -o=../build/${TGT}",
        source="src/compiler.as",
        target="stage2/arrow.ll",
        cwd="src",
        after="stage1")

    # Compile the compiler from llvm IL into native object code.
    ctx(rule="${LLC} -filetype=obj -o=${TGT} ${SRC}",
        source="stage2/arrow.ll",
        target="stage2/arrow.o")

    # Link the compiler into a final executable.
    libs = " ".join(map(lambda x: "-l%s" % x, ctx.env['LIB_LLVM']))
    ctx(rule="${GXX} -o${TGT} ${SRC} %s" % libs,
        source="stage2/arrow.o",
        target="stage2/arrow",
        name="stage2")

    # TODO: Run the test suite on the stage-3 compiler

    # TODO: Do a bit-by-bit equality check on both compilers

    # Copy the stage2 compiler to "build/arrow"
    ctx(rule="cp ${SRC} ${TGT}",
        source="stage2/arrow",
        target="arrow")


def test(ctx):
    print(ws.test._sep("test session starts", "="))
    print(ws.test._sep("tokenize", "-"))
    ws.test._test_tokenizer(ctx)
    print(ws.test._sep("parse", "-"))
    ws.test._test_parser(ctx)
    print(ws.test._sep("parse-fail", "-"))
    ws.test._test_parser_fail(ctx)
    print(ws.test._sep("run", "-"))
    ws.test._test_run(ctx)
    print(ws.test._sep("run-fail", "-"))
    ws.test._test_run_fail(ctx)
    ws.test._print_report()


def _test_tokenize(ctx):
    print(ws.test._sep("test session starts", "="))
    print(ws.test._sep("tokenize", "-"))
    ws.test._test_tokenizer(ctx)
    print(ws.test._sep("tokenize-fail", "-"))
    ws.test._test_tokenizer_fail(ctx)
    ws.test._print_report()

globals()["test:tokenize"] = _test_tokenize

def _test_parse(ctx):
    print(ws.test._sep("test session starts", "="))
    print(ws.test._sep("parse", "-"))
    ws.test._test_parser(ctx)
    print(ws.test._sep("parse-fail", "-"))
    ws.test._test_parser_fail(ctx)
    ws.test._print_report()

globals()["test:parse"] = _test_parse

def _test_run(ctx):
    print(ws.test._sep("test session starts", "="))
    print(ws.test._sep("run", "-"))
    ws.test._test_run(ctx)
    print(ws.test._sep("run-fail", "-"))
    ws.test._test_run_fail(ctx)
    ws.test._print_report()

globals()["test:run"] = _test_run
