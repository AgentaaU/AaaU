(* Coverage-oriented tests for the client command-line parser. *)

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let expect_ok input program args =
  match AaaU.Command_line.split_command input with
  | Error message ->
    fail "expected %S to parse, got error: %s" input message
  | Ok (actual_program, actual_args) ->
    expect
      (actual_program = program && actual_args = args)
      (Printf.sprintf "expected (%S, [%s]), got (%S, [%s])" program
         (String.concat "; " args) actual_program
         (String.concat "; " actual_args))

let expect_error input =
  match AaaU.Command_line.split_command input with
  | Ok _ -> fail "expected %S to fail" input
  | Error _ -> ()

let () =
  expect_ok "a b c" "a" [ "b"; "c" ];
  expect_ok "a\tb" "a" [ "b" ];
  expect_ok "a\nb" "a" [ "b" ];
  expect_ok "a\rb" "a" [ "b" ];
  expect_ok "  spaced  out  " "spaced" [ "out" ];
  expect_ok "'single quoted' arg" "single quoted" [ "arg" ];
  expect_ok "\"double quoted\" arg" "double quoted" [ "arg" ];
  expect_ok "a\\ b" "a b" [];
  expect_ok "\"a\\\"b\"" "a\"b" [];
  expect_ok "one 'two three' \"four five\"" "one" [ "two three"; "four five" ];
  expect_error "";
  expect_error "   ";
  expect_error "trailing\\";
  expect_error "'unterminated";
  expect_error "\"unterminated";
  expect_error "''";
  expect_error "\"\"";
  print_endline "command line tests passed"
