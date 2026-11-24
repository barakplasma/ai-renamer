// This project targets Bend's native executable.
#ifdef CID(load_config_native)
io_eff(CID(load_config_native), () => io_fail(38));
#endif
#ifdef CID(save_config_native)
io_eff(CID(save_config_native), () => io_fail(38));
#endif
#ifdef CID(scan_native)
io_eff(CID(scan_native), () => io_fail(38));
#endif
#ifdef CID(begin_run_native)
io_eff(CID(begin_run_native), () => io_fail(38));
#endif
#ifdef CID(rename_file_native)
io_eff(CID(rename_file_native), () => io_fail(38));
#endif
#ifdef CID(rollback_native)
io_eff(CID(rollback_native), () => io_fail(38));
#endif
#ifdef CID(runs_native)
io_eff(CID(runs_native), () => io_fail(38));
#endif
#ifdef CID(http_native)
io_eff(CID(http_native), () => io_fail(38));
#endif
#ifdef CID(material_native)
io_eff(CID(material_native), () => io_fail(38));
#endif
