//! Windows Service management and execution for MT-Copier Central Hub.
//!
//! Provides native integration with Windows Service Control Manager (SCM):
//! - Zero-console daemonization
//! - Automatic restart on crash (5s backoff)
//! - System startup automatic launch (boot before user logon)
//! - Clean SCM Stop & Shutdown handling via EXIT flag

#[cfg(windows)]
pub mod win_service {
    use std::ffi::OsString;
    use std::fs::OpenOptions;
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;
    use std::sync::atomic::Ordering;
    use std::sync::Mutex;
    use std::time::Duration;
    use crate::lockx::LockExt;

    use windows_service::{
        define_windows_service,
        service::{
            ServiceAccess, ServiceAction, ServiceActionType, ServiceControl,
            ServiceControlAccept, ServiceErrorControl, ServiceExitCode,
            ServiceFailureActions, ServiceFailureResetPeriod, ServiceInfo,
            ServiceStartType, ServiceState, ServiceStatus, ServiceType,
        },
        service_control_handler::{self, ServiceControlHandlerResult},
        service_dispatcher,
        service_manager::{ServiceManager, ServiceManagerAccess},
    };

    pub const PRIMARY_SERVICE_NAME: &str = "MTCopierPrimary";
    pub const PRIMARY_DISPLAY_NAME: &str = "MT-Copier Primary Hub";
    pub const STANDBY_SERVICE_NAME: &str = "MTCopierStandby";
    pub const STANDBY_DISPLAY_NAME: &str = "MT-Copier Standby Hub";

    /// H4: the SCM name for a role, optionally suffixed for a second instance.
    ///
    /// The names used to be hard-coded, so a machine could host exactly one
    /// Primary and one Standby - installing a second Primary silently reconfigured
    /// the first one instead of creating a second service, and both would then
    /// fight over the same ports and the same data files. The suffix is what makes
    /// `install_services.bat` able to describe more than one deployment per host.
    pub fn service_name(role: &str, instance: Option<&str>) -> Result<String, String> {
        let base = match role {
            "primary" => PRIMARY_SERVICE_NAME,
            "standby" => STANDBY_SERVICE_NAME,
            other => return Err(format!("Unknown service role '{}'. Use 'primary' or 'standby'.", other)),
        };
        match instance {
            Some(i) if !i.is_empty() => Ok(format!("{}_{}", base, i)),
            _ => Ok(base.to_string()),
        }
    }

    /// H4: the log file must live beside THIS instance's data, not beside the exe.
    ///
    /// `hub_service_main` used to open `hub_<svc>_service.log` relative to whatever
    /// the process' working directory happened to be, *before* anything had looked
    /// at `--workdir`. `main()` does chdir on `--workdir` early, so the common case
    /// worked by luck; a service installed with a workdir the account cannot enter,
    /// or a start that skips that path, dropped the log in `System32` instead. The
    /// directory is now resolved explicitly from the arguments SCM recorded.
    fn resolve_workdir(cmdline: &[OsString]) -> Option<std::path::PathBuf> {
        let scan = |tokens: &mut dyn Iterator<Item = OsString>| -> Option<std::path::PathBuf> {
            let it = tokens;
            while let Some(a) = it.next() {
                if a == "--workdir" {
                    return it.next().map(std::path::PathBuf::from);
                }
            }
            None
        };
        scan(&mut cmdline.iter().cloned()).or_else(|| {
            scan(&mut std::env::args_os())
        })
    }

    pub fn redirect_stdio_to_log(path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        let raw_handle = file.as_raw_handle();

        #[link(name = "kernel32")]
        extern "system" {
            fn SetStdHandle(nStdHandle: u32, hHandle: *mut std::ffi::c_void) -> i32;
        }
        const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // -11
        const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4;  // -12

        unsafe {
            SetStdHandle(STD_OUTPUT_HANDLE, raw_handle);
            SetStdHandle(STD_ERROR_HANDLE, raw_handle);
        }
        //--- H4: keep the handle in a static instead of `mem::forget`. The file must
        //--- stay open for the life of the process either way, but the handle is now
        //--- owned and reachable rather than deliberately leaked - and a second call
        //--- (which would otherwise orphan the first handle) replaces it cleanly.
        static LOG_HANDLE: Mutex<Option<std::fs::File>> = Mutex::new(None);
        *LOG_HANDLE.lock_or_recover() = Some(file);
        Ok(())
    }

    define_windows_service!(ffi_service_main, hub_service_main);

    // Static holder for service name being run
    static RUNNING_SERVICE_NAME: Mutex<Option<String>> = Mutex::new(None);

    pub fn run_as_service(service_name: &str) -> Result<(), String> {
        {
            let mut name_guard = RUNNING_SERVICE_NAME.lock_or_recover();
            *name_guard = Some(service_name.to_string());
        }
        service_dispatcher::start(service_name, ffi_service_main)
            .map_err(|e| format!("Failed to start service dispatcher for {}: {}", service_name, e))
    }

    pub fn hub_service_main(args: Vec<OsString>) {
        let service_name = {
            RUNNING_SERVICE_NAME
                .lock_or_recover()
                .clone()
                .unwrap_or_else(|| PRIMARY_SERVICE_NAME.to_string())
        };

        //--- H4: resolve the log directory from the arguments SCM recorded, BEFORE
        //--- opening the log. Falling back to the current directory (which `main()`
        //--- has already set to --workdir) and then to the exe's directory keeps the
        //--- old behaviour when no workdir was configured.
        let log_name = format!("hub_{}_service.log", service_name.to_lowercase());
        let log_path = resolve_workdir(&args)
            .map(|wd| wd.join(&log_name))
            .or_else(|| {
                std::env::current_exe()
                    .ok()
                    .and_then(|p| p.parent().map(|d| d.join(&log_name)))
            })
            .unwrap_or_else(|| std::path::PathBuf::from(&log_name));
        let _ = redirect_stdio_to_log(&log_path);

        println!("[service] Initializing Windows Service '{}'...", service_name);
        println!("[service] stdout/stderr -> {}", log_path.display());

        let status_handle_slot: std::sync::Arc<Mutex<Option<service_control_handler::ServiceStatusHandle>>> =
            std::sync::Arc::new(Mutex::new(None));
        let handle_for_event = std::sync::Arc::clone(&status_handle_slot);

        let event_handler = move |control_event| -> ServiceControlHandlerResult {
            match control_event {
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    println!("[service] Received SCM Stop/Shutdown event. Signalling hub exit...");
                    // OPT-02: Report StopPending with 10s wait hint so SCM doesn't pop timeout dialog
                    if let Ok(guard) = handle_for_event.lock() {
                        if let Some(ref h) = *guard {
                            let _ = h.set_service_status(ServiceStatus {
                                service_type: ServiceType::OWN_PROCESS,
                                current_state: ServiceState::StopPending,
                                controls_accepted: ServiceControlAccept::empty(),
                                exit_code: ServiceExitCode::Win32(0),
                                checkpoint: 1,
                                wait_hint: Duration::from_secs(10),
                                process_id: None,
                            });
                        }
                    }
                    crate::EXIT.store(true, Ordering::SeqCst);
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        };

        let status_handle = match service_control_handler::register(&service_name, event_handler) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("[service] Failed to register service control handler: {}", e);
                return;
            }
        };

        {
            if let Ok(mut guard) = status_handle_slot.lock() {
                *guard = Some(status_handle.clone());
            }
        }

        // Tell SCM that the service is running
        let _ = status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        });

        // Run the main hub engine using the parsed command line args
        match crate::parse_args() {
            Ok(args) => {
                if let Err(e) = crate::run_hub(args) {
                    eprintln!("[service] Hub execution error: {}", e);
                }
            }
            Err(e) => {
                eprintln!("[service] Failed to parse hub arguments in service mode: {}", e);
            }
        }

        // Tell SCM that the service has stopped cleanly
        println!("[service] Service '{}' has stopped.", service_name);
        let _ = status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        });
    }

    pub fn install(
        role: &str,
        workdir: Option<&Path>,
        instance: Option<&str>,
        custom_args: &[String],
    ) -> Result<(), String> {
        let sname = service_name(role, instance)?;
        let (display_name, desc, default_args) = match role {
            "primary" => (
                match instance {
                    Some(i) if !i.is_empty() => format!("{} ({})", PRIMARY_DISPLAY_NAME, i),
                    _ => PRIMARY_DISPLAY_NAME.to_string(),
                },
                "MT-Copier Central Hub (Primary Node) - High-performance ZeroMQ & HTTPS router for trade replication",
                vec![
                    "--port".to_string(), "6000".to_string(),
                    "--http".to_string(), "0.0.0.0:6010".to_string(),
                    "--role".to_string(), "primary".to_string(),
                ],
            ),
            "standby" => (
                match instance {
                    Some(i) if !i.is_empty() => format!("{} ({})", STANDBY_DISPLAY_NAME, i),
                    _ => STANDBY_DISPLAY_NAME.to_string(),
                },
                "MT-Copier Central Hub (Standby Mirror Node) - High-performance ZeroMQ & HTTPS router for trade replication",
                vec![
                    "--port".to_string(), "6000".to_string(),
                    "--http".to_string(), "0.0.0.0:6010".to_string(),
                    "--role".to_string(), "standby".to_string(),
                    "--cluster-state".to_string(), r"standby_data\cluster_state.json".to_string(),
                    "--config".to_string(), r"standby_data\config_revisions.jsonl".to_string(),
                    "--commands".to_string(), r"standby_data\commands.jsonl".to_string(),
                    "--users".to_string(), r"standby_data\users.json".to_string(),
                    "--notifications".to_string(), r"standby_data\alert_channels.json".to_string(),
                    "--curve-clients".to_string(), r"standby_data\curve_clients.txt".to_string(),
                    "--curve-keys".to_string(), "curve_hub.keys".to_string(),
                    "--audit".to_string(), r"standby_data\audit.jsonl".to_string(),
                ],
            ),
            other => return Err(format!("Unknown service role '{}'. Use 'primary' or 'standby'.", other)),
        };

        let current_exe = std::env::current_exe()
            .map_err(|e| format!("Cannot locate current executable path: {}", e))?;

        let resolved_workdir = match workdir {
            Some(w) => w.to_path_buf(),
            None => std::env::current_dir().unwrap_or_else(|_| {
                current_exe
                    .parent()
                    .unwrap_or(Path::new("."))
                    .to_path_buf()
            }),
        };

        let manager_access = ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE;
        let service_manager = ServiceManager::local_computer(None::<&str>, manager_access).map_err(|e| {
            format!(
                "Failed to connect to Windows Service Manager: {}. (Please run as Administrator!)",
                e
            )
        })?;

        let mut launch_args = vec![
            OsString::from("--service-run"),
            OsString::from(sname.clone()),
            OsString::from("--workdir"),
            resolved_workdir.as_os_str().to_os_string(),
        ];

        let args_to_use = if !custom_args.is_empty() {
            custom_args
        } else {
            &default_args
        };

        for a in args_to_use {
            launch_args.push(OsString::from(a));
        }

        let service_info = ServiceInfo {
            name: OsString::from(sname.clone()),
            display_name: OsString::from(display_name),
            service_type: ServiceType::OWN_PROCESS,
            start_type: ServiceStartType::AutoStart,
            error_control: ServiceErrorControl::Normal,
            executable_path: current_exe,
            launch_arguments: launch_args,
            dependencies: vec![],
            account_name: None, // Run as LocalSystem
            account_password: None,
        };

        let service_access = ServiceAccess::QUERY_CONFIG
            | ServiceAccess::CHANGE_CONFIG
            | ServiceAccess::START
            | ServiceAccess::STOP
            | ServiceAccess::DELETE;

        let service = match service_manager.open_service(&sname, service_access) {
            Ok(s) => {
                println!("[service] Service '{}' already registered. Updating configuration...", sname);
                s.change_config(&service_info)
                    .map_err(|e| format!("Failed to update configuration for service '{}': {}", sname, e))?;
                s
            }
            Err(_) => {
                println!("[service] Registering new Windows Service '{}'...", sname);
                service_manager
                    .create_service(&service_info, service_access)
                    .map_err(|e| format!("Failed to create service '{}': {}", sname, e))?
            }
        };

        let _ = service.set_description(desc);

        // Configure auto-restart on failure (restart in 5 seconds, reset failure count after 1 day)
        let actions = vec![
            ServiceAction {
                action_type: ServiceActionType::Restart,
                delay: Duration::from_secs(5),
            },
            ServiceAction {
                action_type: ServiceActionType::Restart,
                delay: Duration::from_secs(5),
            },
            ServiceAction {
                action_type: ServiceActionType::Restart,
                delay: Duration::from_secs(5),
            },
        ];
        let failure_actions = ServiceFailureActions {
            reset_period: ServiceFailureResetPeriod::After(Duration::from_secs(86400)),
            reboot_msg: None,
            command: None,
            actions: Some(actions),
        };
        let _ = service.update_failure_actions(failure_actions);
        let _ = service.set_failure_actions_on_non_crash_failures(true);

        println!(
            "[service] SUCCESS: Service '{}' configured with AutoStart and 5s auto-recovery.",
            sname
        );
        Ok(())
    }

    pub fn uninstall(role: &str, instance: Option<&str>) -> Result<(), String> {
        let sname = service_name(role, instance)?;

        let service_manager = ServiceManager::local_computer(
            None::<&str>,
            ServiceManagerAccess::CONNECT,
        )
        .map_err(|e| format!("Cannot connect to SCM: {}. (Please run as Administrator!)", e))?;

        let service = service_manager
            .open_service(
                &sname,
                ServiceAccess::STOP | ServiceAccess::DELETE | ServiceAccess::QUERY_STATUS,
            )
            .map_err(|e| format!("Cannot open service '{}': {}", sname, e))?;

        let _ = service.stop();
        std::thread::sleep(Duration::from_millis(500));

        service
            .delete()
            .map_err(|e| format!("Failed to delete service '{}': {}", sname, e))?;
        println!("[service] SUCCESS: Service '{}' uninstalled successfully.", sname);
        Ok(())
    }

    pub fn start(role: &str, instance: Option<&str>) -> Result<(), String> {
        let sname = service_name(role, instance)?;
        let service_manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|e| format!("Cannot connect to SCM: {}", e))?;
        let service = service_manager
            .open_service(&sname, ServiceAccess::START)
            .map_err(|e| format!("Cannot open service '{}': {}", sname, e))?;
        let no_args: &[&str] = &[];
        service
            .start(no_args)
            .map_err(|e| format!("Failed to start service '{}': {}", sname, e))?;
        println!("[service] Started service '{}'.", sname);
        Ok(())
    }

    pub fn stop(role: &str, instance: Option<&str>) -> Result<(), String> {
        let sname = service_name(role, instance)?;
        let service_manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|e| format!("Cannot connect to SCM: {}", e))?;
        let service = service_manager
            .open_service(&sname, ServiceAccess::STOP)
            .map_err(|e| format!("Cannot open service '{}': {}", sname, e))?;
        service
            .stop()
            .map_err(|e| format!("Failed to stop service '{}': {}", sname, e))?;
        println!("[service] Stopped service '{}'.", sname);
        Ok(())
    }

    pub fn status(role: &str, instance: Option<&str>) -> Result<String, String> {
        let sname = service_name(role, instance)?;
        let service_manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|e| format!("Cannot connect to SCM: {}", e))?;
        let service = service_manager
            .open_service(&sname, ServiceAccess::QUERY_STATUS)
            .map_err(|e| format!("Service '{}' is not installed or inaccessible: {}", sname, e))?;
        let st = service
            .query_status()
            .map_err(|e| format!("Failed to query status: {}", e))?;
        let state_str = match st.current_state {
            ServiceState::Running => "RUNNING",
            ServiceState::Stopped => "STOPPED",
            ServiceState::StartPending => "START_PENDING",
            ServiceState::StopPending => "STOP_PENDING",
            ServiceState::Paused => "PAUSED",
            ServiceState::PausePending => "PAUSE_PENDING",
            ServiceState::ContinuePending => "CONTINUE_PENDING",
        };
        Ok(format!("{}: {}", sname, state_str))
    }
}

#[cfg(not(windows))]
pub mod win_service {
    use std::path::Path;

    pub fn run_as_service(_name: &str) -> Result<(), String> {
        Err("Windows Service mode is only supported on Windows.".to_string())
    }
    pub fn install(
        _role: &str,
        _workdir: Option<&Path>,
        _instance: Option<&str>,
        _custom_args: &[String],
    ) -> Result<(), String> {
        Err("Windows Service installation is only supported on Windows.".to_string())
    }
    pub fn uninstall(_role: &str, _instance: Option<&str>) -> Result<(), String> {
        Err("Windows Service uninstallation is only supported on Windows.".to_string())
    }
    pub fn start(_role: &str, _instance: Option<&str>) -> Result<(), String> {
        Err("Windows Service start is only supported on Windows.".to_string())
    }
    pub fn stop(_role: &str, _instance: Option<&str>) -> Result<(), String> {
        Err("Windows Service stop is only supported on Windows.".to_string())
    }
    pub fn status(_role: &str, _instance: Option<&str>) -> Result<String, String> {
        Err("Windows Service status is only supported on Windows.".to_string())
    }
}
