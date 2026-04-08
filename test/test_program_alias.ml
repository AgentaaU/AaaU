(** Test client program alias expansion. *)

let fail fmt = Printf.ksprintf failwith fmt

let expect_alias alias expected =
  match AaaU.Command_line.expand_program_alias alias with
  | Some actual when actual = expected -> ()
  | Some actual ->
    fail "expected alias %S to expand to %S, got %S" alias expected actual
  | None ->
    fail "expected alias %S to expand to %S, got no expansion" alias expected

let expect_no_alias alias =
  match AaaU.Command_line.expand_program_alias alias with
  | Some actual ->
    fail "expected alias %S to be rejected, got %S" alias actual
  | None -> ()

let expect_expanded_split alias expected_program expected_args =
  match AaaU.Command_line.expand_program_alias alias with
  | None ->
    fail "expected alias %S to expand before split" alias
  | Some expanded ->
    match AaaU.Command_line.split_command expanded with
    | Error e ->
      fail "expected expanded alias %S to split, got error: %s" alias e
    | Ok (program, args) ->
      if program <> expected_program then
        fail "expected expanded alias %S to use program %S, got %S"
          alias expected_program program;
      if args <> expected_args then
        fail "expected expanded alias %S args [%s], got [%s]"
          alias
          (String.concat "; " expected_args)
          (String.concat "; " args)

let () =
  Printf.printf "=== Test: Program alias expansion ===\n%!";
  expect_alias "codex" "codex --dangerously-bypass-approvals-and-sandbox";
  expect_alias "claude" "claude --dangerously-skip-permissions";
  expect_expanded_split "codex" "codex" ["--dangerously-bypass-approvals-and-sandbox"];
  expect_expanded_split "claude" "claude" ["--dangerously-skip-permissions"];
  expect_no_alias "unknown";
  expect_no_alias "Codex";
  expect_no_alias "CLAUDE";
  expect_no_alias " claude";
  expect_no_alias "claude ";
  expect_no_alias "";
  Printf.printf "PASS\n%!"
