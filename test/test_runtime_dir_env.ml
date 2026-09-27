(** Test the XDG_RUNTIME_DIR exposure used for agent D-Bus/systemd access *)

open AaaU

let fail fmt = Printf.ksprintf failwith fmt

let test_runtime_dir_env () =
  (* A missing runtime directory must not be exported: a dangling
     XDG_RUNTIME_DIR makes D-Bus clients fail in confusing ways. *)
  if Session.runtime_dir_env ~exists:(fun _ -> false) ~agent_uid:1000 () <> [] then
    fail "expected no environment when the runtime directory is missing";

  (* An unresolved account must not produce a bogus /run/user/-1 path. *)
  if Session.runtime_dir_env ~exists:(fun _ -> true) ~agent_uid:(-1) () <> [] then
    fail "expected no environment for an invalid uid";

  (* A lingering or logged-in account has /run/user/<uid> and gains the
     variable so `systemctl --user` and other D-Bus clients work. *)
  (match Session.runtime_dir_env ~exists:(fun _ -> true) ~agent_uid:1000 () with
   | [ "XDG_RUNTIME_DIR", "/run/user/1000" ] -> ()
   | _ -> fail "expected XDG_RUNTIME_DIR=/run/user/1000");

  print_endline "runtime dir env tests passed"

let () =
  Printf.printf "=== Test: Agent runtime directory environment ===\n%!";
  test_runtime_dir_env ()
