# Copyright (c) 2011 The LevelDB Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file. See the AUTHORS file for names of contributors.

# Inherit some settings from environment variables, if available
INSTALL_PATH ?= $(CURDIR)

#-----------------------------------------------

ifneq ($(MAKECMDGOALS),dbg)
OPT += -O2 -fno-omit-frame-pointer -momit-leaf-frame-pointer
else
# intentionally left blank
endif

ifeq ($(MAKECMDGOALS),shared_lib)
PLATFORM_SHARED_LDFLAGS=-fPIC
endif
#-----------------------------------------------

# detect what platform we're building on
$(shell (export ROCKSDB_ROOT=$(CURDIR); $(CURDIR)/build_tools/build_detect_platform $(CURDIR)/build_config.mk))
# this file is generated by the previous line to set build flags and sources
include build_config.mk

# ASAN doesn't work well with jemalloc. If we're compiling with ASAN, we should use regular malloc.
ifdef COMPILE_WITH_ASAN
	# ASAN compile flags
	EXEC_LDFLAGS += -fsanitize=address
	PLATFORM_CCFLAGS += -fsanitize=address
	PLATFORM_CXXFLAGS += -fsanitize=address
else
	# if we're not compiling with ASAN, use jemalloc
	EXEC_LDFLAGS := $(JEMALLOC_LIB) $(EXEC_LDFLAGS)
	PLATFORM_CXXFLAGS += $(JEMALLOC_INCLUDE) -DHAVE_JEMALLOC
	PLATFORM_CCFLAGS += $(JEMALLOC_INCLUDE) -DHAVE_JEMALLOC
endif

WARNING_FLAGS = -Wall -Werror
CFLAGS += -g $(WARNING_FLAGS) -I. -I./include $(PLATFORM_CCFLAGS) $(OPT)
CXXFLAGS += -g $(WARNING_FLAGS) -I. -I./include $(PLATFORM_CXXFLAGS) $(OPT) -Woverloaded-virtual

LDFLAGS += $(PLATFORM_LDFLAGS)

LIBOBJECTS = $(SOURCES:.cc=.o)
LIBOBJECTS += $(SOURCESCPP:.cpp=.o)
MEMENVOBJECTS = $(MEMENV_SOURCES:.cc=.o)

TESTUTIL = ./util/testutil.o
TESTHARNESS = ./util/testharness.o $(TESTUTIL)
VALGRIND_ERROR = 2
VALGRIND_DIR = build_tools/VALGRIND_LOGS
VALGRIND_VER := $(join $(VALGRIND_VER),valgrind)
VALGRIND_OPTS = --error-exitcode=$(VALGRIND_ERROR) --leak-check=full

TESTS = \
	db_test \
	block_hash_index_test \
	autovector_test \
	table_properties_collector_test \
	arena_test \
	auto_roll_logger_test \
	block_test \
	bloom_test \
	dynamic_bloom_test \
	c_test \
	cache_test \
	coding_test \
	corruption_test \
	crc32c_test \
	dbformat_test \
	env_test \
	blob_store_test \
	filelock_test \
	filename_test \
	filter_block_test \
	histogram_test \
	log_test \
	manual_compaction_test \
	memenv_test \
	merge_test \
	redis_test \
	reduce_levels_test \
	plain_table_db_test \
  prefix_test \
	simple_table_db_test \
	skiplist_test \
	stringappend_test \
	ttl_test \
	backupable_db_test \
	version_edit_test \
	version_set_test \
	write_batch_test\
	deletefile_test \
	table_test \
	thread_local_test

TOOLS = \
        sst_dump \
        db_stress \
        ldb \
	db_repl_stress \
	blob_store_bench


PROGRAMS = db_bench signal_test table_reader_bench $(TESTS) $(TOOLS)
BENCHMARKS = db_bench_sqlite3 db_bench_tree_db table_reader_bench

# The library name is configurable since we are maintaining libraries of both
# debug/release mode.
ifeq ($(LIBNAME),)
        LIBNAME=librocksdb
endif
LIBRARY = ${LIBNAME}.a
MEMENVLIBRARY = libmemenv.a

default: all

#-----------------------------------------------
# Create platform independent shared libraries.
#-----------------------------------------------
ifneq ($(PLATFORM_SHARED_EXT),)

ifneq ($(PLATFORM_SHARED_VERSIONED),true)
SHARED1 = ${LIBNAME}.$(PLATFORM_SHARED_EXT)
SHARED2 = $(SHARED1)
SHARED3 = $(SHARED1)
SHARED = $(SHARED1)
else
# Update db.h if you change these.
SHARED_MAJOR = 2
SHARED_MINOR = 0
SHARED1 = ${LIBNAME}.$(PLATFORM_SHARED_EXT)
SHARED2 = $(SHARED1).$(SHARED_MAJOR)
SHARED3 = $(SHARED1).$(SHARED_MAJOR).$(SHARED_MINOR)
SHARED = $(SHARED1) $(SHARED2) $(SHARED3)
$(SHARED1): $(SHARED3)
	ln -fs $(SHARED3) $(SHARED1)
$(SHARED2): $(SHARED3)
	ln -fs $(SHARED3) $(SHARED2)
endif

$(SHARED3):
	$(CXX) $(PLATFORM_SHARED_LDFLAGS)$(SHARED2) $(CXXFLAGS) $(PLATFORM_SHARED_CFLAGS) $(LDFLAGS) $(SOURCES) -o $@

endif  # PLATFORM_SHARED_EXT

.PHONY: blackbox_crash_test check clean coverage crash_test ldb_tests \
	release tags valgrind_check whitebox_crash_test format shared_lib all \
	dbg

all: $(LIBRARY) $(PROGRAMS)

dbg: $(LIBRARY) $(PROGRAMS)

# Will also generate shared libraries.
release:
	$(MAKE) clean
	OPT="-DNDEBUG -O2" $(MAKE) all -j32

coverage:
	$(MAKE) clean
	COVERAGEFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS+="-lgcov" $(MAKE) all check -j32
	(cd coverage; ./coverage_test.sh)
	# Delete intermediate files
	find . -type f -regex ".*\.\(\(gcda\)\|\(gcno\)\)" -exec rm {} \;

check: $(PROGRAMS) $(TESTS) $(TOOLS)
	for t in $(TESTS); do echo "***** Running $$t"; ./$$t || exit 1; done
	python tools/ldb_test.py

ldb_tests: all $(PROGRAMS) $(TOOLS)
	python tools/ldb_test.py

crash_test: blackbox_crash_test whitebox_crash_test

blackbox_crash_test: db_stress
	python -u tools/db_crashtest.py

whitebox_crash_test: db_stress
	python -u tools/db_crashtest2.py

asan_check:
	$(MAKE) clean
	COMPILE_WITH_ASAN=1 $(MAKE) check -j32
	$(MAKE) clean

asan_crash_test:
	$(MAKE) clean
	COMPILE_WITH_ASAN=1 $(MAKE) crash_test -j32
	$(MAKE) clean

valgrind_check: all $(PROGRAMS) $(TESTS)
	mkdir -p $(VALGRIND_DIR)
	echo TESTS THAT HAVE VALGRIND ERRORS > $(VALGRIND_DIR)/valgrind_failed_tests; \
	echo TIMES in seconds TAKEN BY TESTS ON VALGRIND > $(VALGRIND_DIR)/valgrind_tests_times; \
	for t in $(filter-out skiplist_test,$(TESTS)); do \
		stime=`date '+%s'`; \
		$(VALGRIND_VER) $(VALGRIND_OPTS) ./$$t; \
		if [ $$? -eq $(VALGRIND_ERROR) ] ; then \
			echo $$t >> $(VALGRIND_DIR)/valgrind_failed_tests; \
		fi; \
		etime=`date '+%s'`; \
		echo $$t $$((etime - stime)) >> $(VALGRIND_DIR)/valgrind_tests_times; \
	done

clean:
	-rm -f $(PROGRAMS) $(BENCHMARKS) $(LIBRARY) $(SHARED) $(MEMENVLIBRARY) build_config.mk
	-rm -rf ios-x86/* ios-arm/*
	-find . -name "*.[od]" -exec rm {} \;
	-find . -type f -regex ".*\.\(\(gcda\)\|\(gcno\)\)" -exec rm {} \;
tags:
	ctags * -R
	cscope -b `find . -name '*.cc'` `find . -name '*.h'`

format:
	build_tools/format-diff.sh

shared_lib: $(SHARED)

# ---------------------------------------------------------------------------
# 	Unit tests and tools
# ---------------------------------------------------------------------------
$(LIBRARY): $(LIBOBJECTS)
	rm -f $@
	$(AR) -rs $@ $(LIBOBJECTS)

db_bench: db/db_bench.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) db/db_bench.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

block_hash_index_test: table/block_hash_index_test.o $(LIBOBJECTS) $(TESTHARNESS)
	 $(CXX) table/block_hash_index_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

db_stress: tools/db_stress.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) tools/db_stress.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

db_repl_stress: tools/db_repl_stress.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) tools/db_repl_stress.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

blob_store_bench: tools/blob_store_bench.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) tools/blob_store_bench.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

db_bench_sqlite3: doc/bench/db_bench_sqlite3.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) doc/bench/db_bench_sqlite3.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) -lsqlite3 $(COVERAGEFLAGS)

db_bench_tree_db: doc/bench/db_bench_tree_db.o $(LIBOBJECTS) $(TESTUTIL)
	$(CXX) doc/bench/db_bench_tree_db.o $(LIBOBJECTS) $(TESTUTIL) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) -lkyotocabinet $(COVERAGEFLAGS)

signal_test: util/signal_test.o $(LIBOBJECTS)
	$(CXX) util/signal_test.o $(LIBOBJECTS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

arena_test: util/arena_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/arena_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

autovector_test: util/autovector_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/autovector_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

table_properties_collector_test: db/table_properties_collector_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/table_properties_collector_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

bloom_test: util/bloom_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/bloom_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

dynamic_bloom_test: util/dynamic_bloom_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/dynamic_bloom_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

c_test: db/c_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/c_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

cache_test: util/cache_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/cache_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

coding_test: util/coding_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/coding_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

blob_store_test: util/blob_store_test.o $(LIBOBJECTS) $(TESTHARNESS) $(TESTUTIL)
	$(CXX) util/blob_store_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o$@ $(LDFLAGS) $(COVERAGEFLAGS)

stringappend_test: utilities/merge_operators/string_append/stringappend_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) utilities/merge_operators/string_append/stringappend_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

redis_test: utilities/redis/redis_lists_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) utilities/redis/redis_lists_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

histogram_test: util/histogram_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/histogram_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o$@ $(LDFLAGS) $(COVERAGEFLAGS)

thread_local_test: util/thread_local_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/thread_local_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

corruption_test: db/corruption_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/corruption_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

crc32c_test: util/crc32c_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/crc32c_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

db_test: db/db_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/db_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

log_write_bench: util/log_write_bench.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/log_write_bench.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS) -pg

plain_table_db_test: db/plain_table_db_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/plain_table_db_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

simple_table_db_test: db/simple_table_db_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/simple_table_db_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

table_reader_bench: table/table_reader_bench.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) table/table_reader_bench.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS) -pg

perf_context_test: db/perf_context_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/perf_context_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS)

prefix_test: db/prefix_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/prefix_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS)

backupable_db_test: utilities/backupable/backupable_db_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) utilities/backupable/backupable_db_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

ttl_test: utilities/ttl/ttl_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) utilities/ttl/ttl_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

dbformat_test: db/dbformat_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/dbformat_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

env_test: util/env_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/env_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

filename_test: db/filename_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/filename_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

filter_block_test: table/filter_block_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) table/filter_block_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

log_test: db/log_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/log_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

table_test: table/table_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) table/table_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

block_test: table/block_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) table/block_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

skiplist_test: db/skiplist_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/skiplist_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

version_edit_test: db/version_edit_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/version_edit_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

version_set_test: db/version_set_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/version_set_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

reduce_levels_test: tools/reduce_levels_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) tools/reduce_levels_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

write_batch_test: db/write_batch_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/write_batch_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

merge_test: db/merge_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/merge_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

deletefile_test: db/deletefile_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) db/deletefile_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS)

$(MEMENVLIBRARY) : $(MEMENVOBJECTS)
	rm -f $@
	$(AR) -rs $@ $(MEMENVOBJECTS)

memenv_test : helpers/memenv/memenv_test.o $(MEMENVOBJECTS) $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) helpers/memenv/memenv_test.o $(MEMENVOBJECTS) $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

manual_compaction_test: util/manual_compaction_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/manual_compaction_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

rocksdb_shell: tools/shell/ShellContext.o tools/shell/ShellState.o tools/shell/LeveldbShell.o tools/shell/DBClientProxy.o tools/shell/ShellContext.h tools/shell/ShellState.h tools/shell/DBClientProxy.h $(LIBOBJECTS)
	$(CXX) tools/shell/ShellContext.o tools/shell/ShellState.o tools/shell/LeveldbShell.o tools/shell/DBClientProxy.o $(LIBOBJECTS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

DBClientProxy_test: tools/shell/test/DBClientProxyTest.o tools/shell/DBClientProxy.o $(LIBRARY)
	$(CXX) tools/shell/test/DBClientProxyTest.o tools/shell/DBClientProxy.o $(LIBRARY) $(EXEC_LDFLAGS) $(EXEC_LDFLAGS) -o $@  $(LDFLAGS) $(COVERAGEFLAGS)

filelock_test: util/filelock_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/filelock_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

auto_roll_logger_test: util/auto_roll_logger_test.o $(LIBOBJECTS) $(TESTHARNESS)
	$(CXX) util/auto_roll_logger_test.o $(LIBOBJECTS) $(TESTHARNESS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

sst_dump: tools/sst_dump.o $(LIBOBJECTS)
	$(CXX) tools/sst_dump.o $(LIBOBJECTS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

ldb: tools/ldb.o $(LIBOBJECTS)
	$(CXX) tools/ldb.o $(LIBOBJECTS) $(EXEC_LDFLAGS) -o $@ $(LDFLAGS) $(COVERAGEFLAGS)

# ---------------------------------------------------------------------------
#  	Platform-specific compilation
# ---------------------------------------------------------------------------

ifeq ($(PLATFORM), IOS)
# For iOS, create universal object files to be used on both the simulator and
# a device.
PLATFORMSROOT=/Applications/Xcode.app/Contents/Developer/Platforms
SIMULATORROOT=$(PLATFORMSROOT)/iPhoneSimulator.platform/Developer
DEVICEROOT=$(PLATFORMSROOT)/iPhoneOS.platform/Developer
IOSVERSION=$(shell defaults read $(PLATFORMSROOT)/iPhoneOS.platform/versionCFBundleShortVersionString)

.cc.o:
	mkdir -p ios-x86/$(dir $@)
	$(SIMULATORROOT)/usr/bin/$(CXX) $(CXXFLAGS) -isysroot $(SIMULATORROOT)/SDKs/iPhoneSimulator$(IOSVERSION).sdk -arch i686 -c $< -o ios-x86/$@ $(COVERAGEFLAGS)
	mkdir -p ios-arm/$(dir $@)
	$(DEVICEROOT)/usr/bin/$(CXX) $(CXXFLAGS) -isysroot $(DEVICEROOT)/SDKs/iPhoneOS$(IOSVERSION).sdk -arch armv6 -arch armv7 -c $< -o ios-arm/$@ $(COVERAGEFLAGS)
	lipo ios-x86/$@ ios-arm/$@ -create -output $@

.c.o:
	mkdir -p ios-x86/$(dir $@)
	$(SIMULATORROOT)/usr/bin/$(CC) $(CFLAGS) -isysroot $(SIMULATORROOT)/SDKs/iPhoneSimulator$(IOSVERSION).sdk -arch i686 -c $< -o ios-x86/$@
	mkdir -p ios-arm/$(dir $@)
	$(DEVICEROOT)/usr/bin/$(CC) $(CFLAGS) -isysroot $(DEVICEROOT)/SDKs/iPhoneOS$(IOSVERSION).sdk -arch armv6 -arch armv7 -c $< -o ios-arm/$@
	lipo ios-x86/$@ ios-arm/$@ -create -output $@

else
.cc.o:
	$(CXX) $(CXXFLAGS) -c $< -o $@ $(COVERAGEFLAGS)

.c.o:
	$(CC) $(CFLAGS) -c $< -o $@
endif

# ---------------------------------------------------------------------------
#  	Source files dependencies detection
# ---------------------------------------------------------------------------

# Add proper dependency support so changing a .h file forces a .cc file to
# rebuild.

# The .d file indicates .cc file's dependencies on .h files. We generate such
# dependency by g++'s -MM option, whose output is a make dependency rule.
# The sed command makes sure the "target" file in the generated .d file has
# the correct path prefix.
%.d: %.cc
	$(CXX) $(CXXFLAGS) $(PLATFORM_SHARED_CFLAGS) -MM $< -o $@
ifeq ($(PLATFORM), OS_MACOSX)
	@sed -i '' -e 's,.*:,$*.o:,' $@
else
	@sed -i -e 's,.*:,$*.o:,' $@
endif

DEPFILES = $(filter-out util/build_version.d,$(SOURCES:.cc=.d))

depend: $(DEPFILES)

# if the make goal is either "clean" or "format", we shouldn't
# try to import the *.d files.
# TODO(kailiu) The unfamiliarity of Make's conditions leads to the ugly
# working solution.
ifneq ($(MAKECMDGOALS),clean)
ifneq ($(MAKECMDGOALS),format)
-include $(DEPFILES)
endif
endif
