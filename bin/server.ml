(** Server entry point *)

open Lwt.Syntax
open Cmdliner

(* Common arguments *)
let socket_path =
  let doc = "Unix socket path for client connections" in
  Arg.(value & opt string "/var/run/aaau.sock" & info ["s"; "socket"] ~docv:"PATH" ~doc)

let shared_group =
  let doc = "Group name for authorized users" in
  Arg.(value & opt string "agent" & info ["g"; "group"] ~docv:"GROUP" ~doc)

let agent_user =
  let doc = "System user for running agents" in
  Arg.(value & opt string "agent" & info ["u"; "user"] ~docv:"USER" ~doc)

let log_dir =
  let doc = "Directory for audit logs" in
  Arg.(value & opt string "/var/log/aaau" & info ["l"; "log-dir"] ~docv:"DIR" ~doc)

(* Run subcommand *)
let daemonize =
  let doc = "Run as daemon" in
  Arg.(value & flag & info ["d"; "daemon"] ~doc)

let default_program =
  let doc = "Default program to run as agent (e.g., /bin/bash, kimi-cli)" in
  Arg.(value & opt string "/bin/bash" & info ["p"; "program"] ~docv:"PROGRAM" ~doc)

let run_server socket_path shared_group agent_user log_dir daemonize default_program =
  (* Check for root privileges *)
  if Unix.getuid () <> 0 then begin
    Printf.eprintf "Error: Need root permission to run server.\n%!";
    Printf.eprintf "Please run with sudo.\n%!";
    exit 1
  end;

  (* Initialize logging *)
  Logs.set_reporter (Logs.format_reporter ());
  Logs.set_level (Some Logs.Info);

  (* Daemonize *)
  if daemonize then begin
    (* Simplified daemonization *)
    let pid = Unix.fork () in
    if pid > 0 then exit 0;
    Unix.setsid () |> ignore;
    Unix.close Unix.stdin;
    Unix.close Unix.stdout;
    Unix.close Unix.stderr
  end;

  (* Create and start server *)
  let server = AaaU.Bridge.create
    ~socket_path
    ~shared_group
    ~agent_user
    ~log_dir
    ~default_program
    ()
  in

  (* Signal handling *)
  let handle_signal _sig =
    Lwt.async (fun () ->
      let* () = Logs_lwt.info (fun m -> m "Shutting down...") in
      AaaU.Bridge.stop server
    )
  in

  Sys.set_signal Sys.sigterm (Signal_handle handle_signal);
  Sys.set_signal Sys.sigint (Signal_handle handle_signal);

  (* Start *)
  Lwt_main.run (AaaU.Bridge.start server)

let run_cmd =
  let doc = "Run the server" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run_server $ socket_path $ shared_group $ agent_user $ log_dir $ daemonize $ default_program)

(* Init subcommand *)
let home_dir =
  let doc = "Home directory for agent user" in
  Arg.(value & opt string "/home/agent" & info ["h"; "home"] ~docv:"DIR" ~doc)

let shell =
  let doc = "Login shell for agent user" in
  Arg.(value & opt string "/bin/false" & info ["shell"] ~docv:"SHELL" ~doc)

(* Check if a user exists *)
let user_exists username =
  try
    let _ = Unix.getpwnam username in
    true
  with Not_found -> false

(* Check if a group exists *)
let group_exists groupname =
  try
    let _ = Unix.getgrnam groupname in
    true
  with Not_found -> false

(* Run a command and return success status *)
let run_command cmd =
  Printf.printf "Running: %s\n%!" cmd;
  let status = Sys.command cmd in
  status = 0

let run_init agent_user shared_group socket_path log_dir home_dir shell =
  (* Check for root privileges *)
  if Unix.getuid () <> 0 then begin
    Printf.eprintf "Error: Need root permission to initialize environment.\n%!";
    Printf.eprintf "Please run with sudo.\n%!";
    exit 1
  end;
  
  Printf.printf "=== AaaU Environment Initialization ===\n\n%!";
  
  let exit_code = ref 0 in
  
  (* Step 1: Create shared group *)
  Printf.printf "[1/5] Checking shared group '%s'...\n%!" shared_group;
  if group_exists shared_group then begin
    Printf.printf "    Group '%s' already exists.\n%!" shared_group
  end else begin
    Printf.printf "    Creating group '%s'...\n%!" shared_group;
    if run_command (Printf.sprintf "groupadd --system %s" shared_group) then
      Printf.printf "    Group created successfully.\n%!"
    else begin
      Printf.eprintf "    ERROR: Failed to create group '%s'.\n%!" shared_group;
      exit_code := 1
    end
  end;
  
  (* Step 2: Create agent user *)
  Printf.printf "\n[2/5] Checking agent user '%s'...\n%!" agent_user;
  if user_exists agent_user then begin
    Printf.printf "    User '%s' already exists.\n%!" agent_user;
    (* Add user to shared group if not already *)
    Printf.printf "    Adding user to group '%s'...\n%!" shared_group;
    ignore (run_command (Printf.sprintf "usermod -aG %s %s" shared_group agent_user))
  end else begin
    Printf.printf "    Creating user '%s'...\n%!" agent_user;
    (* Create parent directory for home if it doesn't exist *)
    if not (Sys.file_exists home_dir) then begin
      Printf.printf "    Creating parent directory '%s'...\n%!" home_dir;
      ignore (run_command (Printf.sprintf "mkdir -p %s" home_dir))
    end;
    (* Create home directory *)
    let home = Filename.concat home_dir agent_user in
    if run_command (Printf.sprintf "useradd --system --gid %s --home-dir %s --shell %s --create-home %s"
                      shared_group home shell agent_user) then begin
      Printf.printf "    User created successfully.\n%!";
      (* Set ownership of home directory *)
      ignore (run_command (Printf.sprintf "chown %s:%s %s" agent_user shared_group home))
    end else begin
      Printf.eprintf "    ERROR: Failed to create user '%s'.\n%!" agent_user;
      exit_code := 1
    end
  end;
  
  (* Step 3: Create socket directory *)
  Printf.printf "\n[3/5] Creating socket directory...\n%!";
  let socket_dir = Filename.dirname socket_path in
  if Sys.file_exists socket_dir then
    Printf.printf "    Directory '%s' already exists.\n%!" socket_dir
  else begin
    if run_command (Printf.sprintf "mkdir -p %s" socket_dir) then begin
      Printf.printf "    Directory created.\n%!";
      (* Set permissions: root:shared_group 775 *)
      if group_exists shared_group then begin
        let gid = (Unix.getgrnam shared_group).Unix.gr_gid in
        Unix.chown socket_dir 0 gid;
        Unix.chmod socket_dir 0o775;
        Printf.printf "    Permissions set (root:%s 775).\n%!" shared_group
      end
    end else begin
      Printf.eprintf "    ERROR: Failed to create directory '%s'.\n%!" socket_dir;
      exit_code := 1
    end
  end;
  
  (* Step 4: Create log directory *)
  Printf.printf "\n[4/5] Creating log directory...\n%!";
  if Sys.file_exists log_dir then
    Printf.printf "    Directory '%s' already exists.\n%!" log_dir
  else begin
    if run_command (Printf.sprintf "mkdir -p %s" log_dir) then begin
      Printf.printf "    Directory created.\n%!";
      (* Set permissions: writable by all, sticky bit *)
      Unix.chmod log_dir 0o1777;
      Printf.printf "    Permissions set (1777).\n%!"
    end else begin
      Printf.eprintf "    ERROR: Failed to create directory '%s'.\n%!" log_dir;
      exit_code := 1
    end
  end;
  
  (* Step 5: Verify sudoers access for agent user *)
  Printf.printf "\n[5/5] Checking sudo configuration...\n%!";
  Printf.printf "    NOTE: Ensure '%s' can run commands as other users.\n%!" agent_user;
  Printf.printf "    You may need to add this to /etc/sudoers:\n%!";
  Printf.printf "        %s ALL=(ALL) NOPASSWD: /bin/bash, /bin/sh, /usr/bin/env\n%!" agent_user;
  
  (* Summary *)
  Printf.printf "\n=== Initialization %s ===\n%!" 
    (if !exit_code = 0 then "Complete" else "Failed");
  Printf.printf "\nNext steps:\n%!";
  Printf.printf "  1. Review and configure sudoers if needed\n%!";
  Printf.printf "  2. Add human users to group '%s':\n%!" shared_group;
  Printf.printf "       usermod -aG %s <username>\n%!" shared_group;
  Printf.printf "  3. Run the server:\n%!";
  Printf.printf "       aaau-server run\n%!";
  
  exit !exit_code

let init_cmd =
  let doc = "Initialize environment for Agent-as-User (creates users, groups, directories)" in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const run_init $ agent_user $ shared_group $ socket_path $ log_dir $ home_dir $ shell)

(* Main command *)
let main_cmd =
  let doc = "Agent-as-User PTY Bridge Server" in
  let info = Cmd.info "aaau-server" ~version:"0.1.0" ~doc in
  Cmd.group info [run_cmd; init_cmd]

let () = exit (Cmd.eval main_cmd)
