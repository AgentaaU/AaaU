(lang dune 3.10)
(name AaaU)
(version 0.1.0)

(generate_opam_files true)

(package
 (name AaaU)
 (synopsis "Secure PTY bridge for Agent-as-User architecture")
 (description "Multi-user PTY bridge with privilege isolation for AI agent sessions")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.0))
  (lwt (>= 5.6))
  (lwt_ppx (>= 2.1))
  (logs (>= 0.7))
  (fmt (>= 0.9))
  (cmdliner (>= 1.1))
  (yojson (>= 2.0))
  (uuidm (>= 0.9))
  (mtime (>= 1.4))
  (cstruct (>= 6.0))
  (bisect_ppx_ng (and (>= 3.0.0) :with-test))))
