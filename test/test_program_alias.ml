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

let () =
  Printf.printf "=== Test: Program alias expansion ===\n%!";
  expect_alias "codex" "codex --dangerously-bypass-approvals-and-sandbox";
  expect_no_alias "unknown";
  Printf.printf "PASS\n%!"
