let fail fmt = Printf.ksprintf failwith fmt

let test_fork_agent_does_not_reparse_arguments () =
  let payload = "$(touch /tmp/aaau-should-stay-literal)" in
  let argv = AaaU.Pty.login_shell_argv ~program:"/bin/echo" ~args:[payload] in
  if Array.length argv <> 8 then
    fail "unexpected argv length: got %d" (Array.length argv);
  if argv.(4) <> "exec \"$@\"" then
    fail "expected positional-argv shell wrapper, got %S" argv.(4);
  if argv.(7) <> payload then
    fail "expected literal payload to survive argv construction, got %S" argv.(7)

let () =
  Printf.printf "=== Test: Fork agent argument injection ===\n%!";
  test_fork_agent_does_not_reparse_arguments ();
  Printf.printf "PASS\n%!"
