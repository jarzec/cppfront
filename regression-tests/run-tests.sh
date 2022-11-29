#!/bin/bash

################
usage() {
    echo "Usage: $0 -c <compiler> [-t <tests to run>]"
    echo "    -c <compiler>     The compiler to use for the test"
    echo "    -t <tests to run> Runs only the provided, comma-separated tests (filenames including .cpp2)"
    echo "                      If the argument is not used all tests are run"
    exit 1
}

optstring="c:t:"
while getopts ${optstring} arg; do
  case "${arg}" in
    c)
        cxx_compiler="${OPTARG}"
        ;;
    t)
        # Replace commas with spaces
        chosen_tests=${OPTARG/,/ }
        ;;
    \?)
        echo "Invalid option: -${OPTARG}."
        echo
        usage
        ;;
    :)
        echo "Missing option argument for -$OPTARG"
        echo
        usage
        ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ -z "$cxx_compiler" ]; then
    echo "Compiler not specified"
    usage
fi

tests=$(ls | grep ".cpp2")
if [[ -n "$chosen_tests" ]]; then
    for test in $chosen_tests; do
        if ! [[ -f "$test" ]]; then
            echo "Requested test ($test) not found"
            exit 1
        fi
    done
    echo "Performing tests:"
    for test in $chosen_tests; do
        echo "    $test"
    done
    echo
    tests="$chosen_tests"
else
    printf "Performing all regression tests\n\n"
fi

expected_results_dir="$(pwd)/test-results"

################
# Get the directory with the exec outputs and compilation command
if [[ "$cxx_compiler" == *"cl.exe"* ]]; then
    compiler_cmd='cl.exe -nologo -std:c++latest -MD -EHsc -I ..\include -experimental:module -Fe:'
	exec_out_dir="$expected_results_dir/msvc-2022"
else
	compiler_cmd="$cxx_compiler -I../include -std=c++20 -pthread -o "
	
	compiler_ver=$("$cxx_compiler" --version)
	if [[ "$compiler_ver" == *"Apple clang version 14.0"* ]]; then
		exec_out_dir="$expected_results_dir/apple-clang-14"
	elif [[ "$compiler_ver" == *"clang version 12.0"* ||
			"$compiler_ver" == *"clang version 14.0"*
		 ]]; then
		exec_out_dir="$expected_results_dir/clang-12"
	elif [[ "$compiler_ver" == *"g++-12"* ||
			"$compiler_ver" == *"g++-13"*
		 ]]; then
		exec_out_dir="$expected_results_dir/gcc-13"
	fi
fi

echo "Directory with reference compilation/execution files to use:"
if [[ -d "$exec_out_dir" ]]; then
    printf  "$exec_out_dir\n\n"
else
    printf "not found for compiler: '$cxx_compiler'\n\n"
fi

################
cppfront_cmd="cppfront.exe"
echo "Building cppfront using the compiler: '$cxx_compiler'"
$compiler_cmd"$cppfront_cmd" ../source/cppfront.cpp
if [[ $? -ne 0 ]]; then
    echo "Compilation using '$cxx_compiler' failed"
    exit 2
fi

################
failed_tests=()
skipped_tests=()
echo "Running regression tests"
for test_file in $tests; do
    test_name=${test_file%.*}
    expeced_output="$expected_results_dir/$test_file.output"
    expected_src="$expected_results_dir/$test_name.cpp"
    test_bin="test.exe"

    # Choose mode - default to mixed code
    descr="mixed cpp1 and cpp2 code"
    opt=""
    # Using naming convention to discriminate pure cpp2 code
    if [[ $test_name == "pure2"* ]]; then
        descr="pure cpp2 code"
        opt="-p"
    fi
    echo "    Testing $descr: $test_name.cpp2"

    ########
    # Run the translation test
    echo "        Generating C++1 code"
    ./"$cppfront_cmd" "$test_file" -o "$expected_src" $opt > "$expeced_output" 2>&1

    failure=0
    compiler_issue=0
    ########
    # Check the output
    if [ -f "$expeced_output" ]; then
        diff_output=$(git diff --ignore-cr-at-eol -- "$expeced_output")
        if [[ -n "$diff_output" ]]; then
            echo "            Non-matching std out/err:"
            printf "\n$diff_output\n\n"
            failure=1
        fi
    else
        echo "            Missing expected output file treaded as failure"
        failure=1
    fi

    ########
    # Check the generated code
    if [ -f "$expected_src" ]; then
        diff_output=$(git diff --ignore-cr-at-eol -- "$expected_src")
        if [[ -n "$diff_output" ]]; then
            echo "            Non-matching generated src:"
            printf "\n$diff_output\n\n"
            failure=1
        else
            ########
            # Compile and run the generated code in a sub-shell
            expected_src_compil_out="$exec_out_dir/$test_name.cpp.output"
            expected_src_exec_out="$exec_out_dir/$test_name.cpp.execution"
            expected_files="$exec_out_dir/$test_name.files"

            if [ -f "$expected_src_compil_out" ]; then
			    echo "        Compiling generated code"
                # The test binary is ompiled locally and later moved to the exeution directory
                # This is done to avoid issues with bash path format with cl.exe
                $compiler_cmd"$test_bin" \
                             $expected_src \
                             > $expected_src_compil_out 2>&1
                if [[ $? -ne 0 ]]; then
                    # Workaround an issue with Apple clang 14.0 missing parts of the std
                    if cat $expected_src_compil_out | grep -q "error: no member named '.*' in namespace 'std"; then
                        echo "            Skipping further checks due to compiler issues:"
                        compiler_issue=1
                    elif cat $expected_src_compil_out | grep -q "error C1011"; then
                        echo "            Skipping further checks due to missing std modules support:"
                        compiler_issue=1
                    else
                        echo "            Compilation failed:"
                        failure=1
                    fi
                    cat $expected_src_compil_out
                    echo
                else
                    diff_output=$(git diff --ignore-cr-at-eol -- "$expected_src_compil_out")
                    if [[ -n "$diff_output" ]]; then
                        echo "            Non-matching comilation output:"
                        printf "\n$diff_output\n\n"
                        failure=1
                    else
                        ########
                        # Execute the compiled code in $exec_out_dir
                        echo "        Executing the compiled test binary"
                        # For some tests the binary needs to be placed in "$exec_out_dir"
                        mv "$test_bin" "$exec_out_dir"
                        # Run the binary in a sub-shell in $exec_out_dir so that files are written there
                        (cd "$exec_out_dir"; ./$test_bin > "$test_name.cpp.execution" 2>&1)
                        diff_output=$(git diff --ignore-cr-at-eol -- "$expected_src_exec_out")
                        if [[ -n "$diff_output" ]]; then
                            echo "            Non-matching execution output:"
                            printf "\n$diff_output\n\n"
                            failure=1
                        fi
                        # If the test generates files check their content
                        if [[ -f "$expected_files" ]]; then
                            echo "        Checking written files"
                            files="$(cat "$expected_files")"
                            for file in ${files/,/ }; do
                                diff_output=$(git diff --ignore-cr-at-eol -- "$exec_out_dir/$file")
                                if [[ -n "$diff_output" ]]; then
                                    echo "            Non-matching content of written file:"
                                    printf "\n$diff_output\n\n"
                                    failure=1
                                fi
                           done
                        fi
                    fi
                fi
            fi
        fi
    elif [[ $(cat "$expeced_output") != *"error"* ]]; then
         echo "            Missing generated src file treated as failure"
         echo "                Failing compilation message needs to contain 'error'"
         failure=1
    fi

    if [[ $failure -ne 0 ]]; then
        failed_tests+=($test_name)
    fi

    if [[ $compiler_issue -ne 0 ]]; then
        skipped_tests+=($test_name)
    fi
done

echo

################
# Report missing reference data direcotry
if [[ ! -d "$exec_out_dir" ]]; then
    echo "Reference data directory not found for compiler: '$cxx_compiler'"
    exit 3
fi

################
# Report skipped/failed tests
num_skipped_tests=$(wc -w <<< ${skipped_tests[@]})
if [ $num_skipped_tests -ne 0 ]; then
    echo "Tests skipped due to compiler issues: $num_skipped_tests"
    for skipped_test in ${skipped_tests[@]}; do
        echo "    $skipped_test.cpp2"
    done
fi

num_failed_tests=$(wc -w <<< ${failed_tests[@]})
if [ $num_failed_tests -ne 0 ]; then
    echo "Failed tests: $num_failed_tests"
    for failed_test in ${failed_tests[@]}; do
        echo "    $failed_test.cpp2"
    done
else
    echo "All tests passed"
fi
exit $num_failed_tests
