#![cfg_attr(not(windows), allow(dead_code, unused_imports))]

#[cfg(windows)]
mod windows_host {
    use serde_json::Value;
    use std::collections::BTreeMap;
    use std::ffi::{c_void, OsStr};
    use std::io::{self, BufRead, BufReader, BufWriter, Write};
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::FromRawHandle;
    use std::path::{Path, PathBuf};
    use std::ptr::{null, null_mut};
    use std::sync::mpsc;
    use std::time::Duration;
    use windows_sys::Win32::Foundation::{
        CloseHandle, LocalFree, SetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT,
    };
    use windows_sys::Win32::Security::Authorization::{
        GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W,
        GRANT_ACCESS, NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, TRUSTEE_IS_SID,
        TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::Isolation::{
        CreateAppContainerProfile, DeriveAppContainerSidFromAppContainerName,
    };
    use windows_sys::Win32::Security::{
        FreeSid, ACL, DACL_SECURITY_INFORMATION, PSID, PSECURITY_DESCRIPTOR,
        SECURITY_ATTRIBUTES, SECURITY_CAPABILITIES, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_ACTIVE_PROCESS,
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION, JOB_OBJECT_LIMIT_JOB_MEMORY,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
        JOB_OBJECT_LIMIT_PROCESS_TIME, JobObjectExtendedLimitInformation,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CreateProcessW, DeleteProcThreadAttributeList, InitializeProcThreadAttributeList,
        ResumeThread, UpdateProcThreadAttribute, CREATE_NO_WINDOW, CREATE_SUSPENDED,
        EXTENDED_STARTUPINFO_PRESENT, PROCESS_INFORMATION,
        PROC_THREAD_ATTRIBUTE_ALL_APPLICATION_PACKAGES_POLICY,
        PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY,
        PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, STARTF_USESTDHANDLES, STARTUPINFOEXW,
    };
    use windows_sys::Win32::System::WindowsProgramming::{
        PROCESS_CREATION_ALL_APPLICATION_PACKAGES_OPT_OUT,
        PROCESS_CREATION_CHILD_PROCESS_RESTRICTED,
    };

    const PROFILE_NAME: &str = "RealmzRemake.ScenarioSandbox.v1";
    const MAX_MESSAGE_BYTES: usize = 1_048_576;
    const MAX_REQUESTS: usize = 4096;
    const WALL_TIMEOUT: Duration = Duration::from_secs(8);
    const MEMORY_LIMIT: usize = 512 * 1024 * 1024;
    const CPU_LIMIT_100NS: i64 = 30 * 10_000_000;
    const MAX_SCRIPT_PAYLOAD_BYTES: u64 = 16 * 1024 * 1024;
    const ERROR_ALREADY_EXISTS_HRESULT: u32 = 0x8007_00B7;

    pub fn run() -> Result<(), String> {
        let args = arguments()?;
        validate_path(&args.godot_executable, "Godot executable", true)?;
        validate_path(&args.project_root, "Remake project root", false)?;
        validate_path(&args.package_root, "scenario package root", false)?;
        if args.protocol != 1 || args.package_hash.len() != 64 || args.nonce.len() != 64 {
            return Err("Invalid sandbox protocol identity".into());
        }

        unsafe {
            let sid = app_container_sid()?;
            let acl_result = (|| {
                let scratch = prepare_scratch(&args, sid)?;
                let result = launch_and_relay(&args, sid, &scratch);
                let _ = std::fs::remove_dir_all(&scratch.root);
                result
            })();
            FreeSid(sid);
            acl_result
        }
    }

    struct Arguments {
        protocol: u32,
        godot_executable: PathBuf,
        project_root: PathBuf,
        package_root: PathBuf,
        package_hash: String,
        nonce: String,
    }

    fn arguments() -> Result<Arguments, String> {
        let values = std::env::args().skip(1).collect::<Vec<_>>();
        let mut map = BTreeMap::new();
        let mut index = 0;
        while index + 1 < values.len() {
            map.insert(values[index].clone(), values[index + 1].clone());
            index += 2;
        }
        let required = |key: &str| {
            map.get(key)
                .cloned()
                .ok_or_else(|| format!("Missing {key}"))
        };
        Ok(Arguments {
            protocol: required("--protocol")?
                .parse()
                .map_err(|_| "Invalid protocol version".to_string())?,
            godot_executable: required("--godot-executable")?.into(),
            project_root: required("--project-root")?.into(),
            package_root: required("--package-root")?.into(),
            package_hash: required("--package-hash")?,
            nonce: required("--nonce")?,
        })
    }

    fn validate_path(path: &Path, label: &str, file: bool) -> Result<(), String> {
        let canonical = path
            .canonicalize()
            .map_err(|error| format!("{label} is unavailable: {error}"))?;
        if file != canonical.is_file() {
            return Err(format!("{label} has the wrong path type"));
        }
        Ok(())
    }

    unsafe fn app_container_sid() -> Result<PSID, String> {
        let name = wide(PROFILE_NAME);
        let display = wide("Realmz Remake Scenario Sandbox");
        let description = wide("Isolated runner for scenario-authored GDScript");
        let mut sid: PSID = null_mut();
        let created = CreateAppContainerProfile(
            name.as_ptr(),
            display.as_ptr(),
            description.as_ptr(),
            null(),
            0,
            &mut sid,
        );
        if created < 0 && created as u32 != ERROR_ALREADY_EXISTS_HRESULT {
            return Err(format!("CreateAppContainerProfile failed: 0x{:08x}", created as u32));
        }
        if created as u32 == ERROR_ALREADY_EXISTS_HRESULT {
            let derived = DeriveAppContainerSidFromAppContainerName(name.as_ptr(), &mut sid);
            if derived < 0 {
                return Err(format!(
                    "DeriveAppContainerSidFromAppContainerName failed: 0x{:08x}",
                    derived as u32
                ));
            }
        }
        if sid.is_null() {
            return Err("Windows returned no AppContainer SID".into());
        }
        Ok(sid)
    }

    unsafe fn grant_path_access(path: &Path, sid: PSID, writable: bool) -> Result<(), String> {
        let path_wide = wide(path.as_os_str());
        let mut old_acl: *mut ACL = null_mut();
        let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
        let status = GetNamedSecurityInfoW(
            path_wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            &mut old_acl,
            null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            return Err(format!("Could not read sandbox path ACL: {status}"));
        }
        let mut access = EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_GENERIC_READ
                | FILE_GENERIC_EXECUTE
                | if writable { FILE_GENERIC_WRITE } else { 0 },
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_UNKNOWN,
                ptstrName: sid as *mut u16,
            },
        };
        let mut new_acl: *mut ACL = null_mut();
        let acl_status = SetEntriesInAclW(1, &mut access, old_acl, &mut new_acl);
        if acl_status != 0 {
            LocalFree(descriptor as *mut c_void);
            return Err(format!("Could not grant sandbox path access: {acl_status}"));
        }
        let set_status = SetNamedSecurityInfoW(
            path_wide.as_ptr() as *mut u16,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            new_acl,
            null(),
        );
        LocalFree(new_acl as *mut c_void);
        LocalFree(descriptor as *mut c_void);
        if set_status != 0 {
            return Err(format!("Could not apply sandbox path ACL: {set_status}"));
        }
        Ok(())
    }

    struct Scratch {
        root: PathBuf,
        executable: PathBuf,
        project: PathBuf,
        package: PathBuf,
    }

    unsafe fn prepare_scratch(args: &Arguments, sid: PSID) -> Result<Scratch, String> {
        let root = std::env::temp_dir().join(format!(
            "realmz-scenario-sandbox-{}-{}",
            std::process::id(),
            &args.nonce[..8]
        ));
        if root.exists() {
            return Err("Sandbox scratch directory already exists".into());
        }
        std::fs::create_dir(&root).map_err(|error| error.to_string())?;
        grant_path_access(&root, sid, true)?;

        let project = root.join("runtime");
        let package = root.join("package");
        std::fs::create_dir(&project).map_err(|error| error.to_string())?;
        std::fs::create_dir_all(package.join("remake/source"))
            .map_err(|error| error.to_string())?;
        std::fs::write(
            project.join("project.godot"),
            b"[application]\nconfig/name=\"Realmz Scenario Sandbox\"\n[display]\nwindow/subwindows/embed_subwindows=false\n[rendering]\nrenderer/rendering_method=\"gl_compatibility\"\n",
        )
        .map_err(|error| error.to_string())?;
        std::fs::copy(
            args.project_root
                .join("scripts/scenario_runtime/sandbox/scenario_sandbox_runner.gd"),
            project.join("runner.gd"),
        )
        .map_err(|error| format!("Could not stage sandbox runner: {error}"))?;

        let source_root = args.package_root.join("remake/source");
        if source_root.is_dir() {
            copy_script_tree(&source_root, &package.join("remake/source"), &mut 0)?;
        }
        let source_executable = runner_executable(&args.godot_executable);
        let executable = root.join("godot-sandbox.exe");
        std::fs::copy(&source_executable, &executable)
            .map_err(|error| format!("Could not stage Godot sandbox executable: {error}"))?;
        Ok(Scratch {
            root,
            executable,
            project,
            package,
        })
    }

    fn runner_executable(configured: &Path) -> PathBuf {
        let file_name = configured
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or_default();
        if let Some(base) = file_name.strip_suffix("_console.exe") {
            let candidate = configured.with_file_name(format!("{base}.exe"));
            if candidate.is_file() {
                return candidate;
            }
        }
        configured.to_path_buf()
    }

    fn copy_script_tree(source: &Path, destination: &Path, total: &mut u64) -> Result<(), String> {
        for entry in std::fs::read_dir(source).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            let metadata = entry
                .path()
                .symlink_metadata()
                .map_err(|error| error.to_string())?;
            if metadata.file_type().is_symlink() {
                return Err("Sandbox script payload may not contain symlinks".into());
            }
            let target = destination.join(entry.file_name());
            if metadata.is_dir() {
                std::fs::create_dir(&target).map_err(|error| error.to_string())?;
                copy_script_tree(&entry.path(), &target, total)?;
            } else if metadata.is_file() {
                if entry.path().extension().and_then(OsStr::to_str) != Some("gd") {
                    return Err("Sandbox source folder contains a non-GDScript payload".into());
                }
                *total = total.saturating_add(metadata.len());
                if *total > MAX_SCRIPT_PAYLOAD_BYTES {
                    return Err("Sandbox script payload exceeds its size limit".into());
                }
                std::fs::copy(entry.path(), target).map_err(|error| error.to_string())?;
            }
        }
        Ok(())
    }

    unsafe fn launch_and_relay(
        args: &Arguments,
        sid: PSID,
        scratch: &Scratch,
    ) -> Result<(), String> {
        let mut child_stdin_read: HANDLE = null_mut();
        let mut parent_stdin_write: HANDLE = null_mut();
        let mut parent_stdout_read: HANDLE = null_mut();
        let mut child_stdout_write: HANDLE = null_mut();
        let pipe_security = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        if CreatePipe(&mut child_stdin_read, &mut parent_stdin_write, &pipe_security, 0) == 0
            || CreatePipe(&mut parent_stdout_read, &mut child_stdout_write, &pipe_security, 0) == 0
        {
            return Err(last_error("CreatePipe"));
        }
        if SetHandleInformation(parent_stdin_write, HANDLE_FLAG_INHERIT, 0) == 0
            || SetHandleInformation(parent_stdout_read, HANDLE_FLAG_INHERIT, 0) == 0
        {
            return Err(last_error("SetHandleInformation"));
        }

        let mut attribute_size = 0usize;
        InitializeProcThreadAttributeList(null_mut(), 3, 0, &mut attribute_size);
        let mut attribute_storage = vec![0u8; attribute_size];
        let attribute_list = attribute_storage.as_mut_ptr() as *mut c_void;
        if InitializeProcThreadAttributeList(attribute_list, 3, 0, &mut attribute_size) == 0 {
            return Err(last_error("InitializeProcThreadAttributeList"));
        }
        let mut security_capabilities = SECURITY_CAPABILITIES {
            AppContainerSid: sid,
            Capabilities: null_mut(),
            CapabilityCount: 0,
            Reserved: 0,
        };
        let all_packages_policy = PROCESS_CREATION_ALL_APPLICATION_PACKAGES_OPT_OUT;
        let child_policy = PROCESS_CREATION_CHILD_PROCESS_RESTRICTED;
        for (attribute, value, size) in [
            (
                PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES as usize,
                &mut security_capabilities as *mut _ as *const c_void,
                size_of::<SECURITY_CAPABILITIES>(),
            ),
            (
                PROC_THREAD_ATTRIBUTE_ALL_APPLICATION_PACKAGES_POLICY as usize,
                &all_packages_policy as *const _ as *const c_void,
                size_of::<u32>(),
            ),
            (
                PROC_THREAD_ATTRIBUTE_CHILD_PROCESS_POLICY as usize,
                &child_policy as *const _ as *const c_void,
                size_of::<u32>(),
            ),
        ] {
            if UpdateProcThreadAttribute(
                attribute_list,
                0,
                attribute,
                value,
                size,
                null_mut(),
                null(),
            ) == 0
            {
                DeleteProcThreadAttributeList(attribute_list);
                return Err(last_error("UpdateProcThreadAttribute"));
            }
        }

        let mut startup: STARTUPINFOEXW = zeroed();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = child_stdin_read;
        startup.StartupInfo.hStdOutput = child_stdout_write;
        startup.StartupInfo.hStdError = child_stdout_write;
        startup.lpAttributeList = attribute_list;
        let mut process: PROCESS_INFORMATION = zeroed();
        let mut command = wide(command_line(args, scratch));
        let application = wide(scratch.executable.as_os_str());
        let flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW;
        let created = CreateProcessW(
            application.as_ptr(),
            command.as_mut_ptr(),
            null(),
            null(),
            1,
            flags,
            null(),
            null(),
            &startup.StartupInfo,
            &mut process,
        );
        DeleteProcThreadAttributeList(attribute_list);
        CloseHandle(child_stdin_read);
        CloseHandle(child_stdout_write);
        if created == 0 {
            return Err(last_error("CreateProcessW"));
        }

        let job = create_limited_job()?;
        if AssignProcessToJobObject(job, process.hProcess) == 0 {
            CloseHandle(job);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return Err(last_error("AssignProcessToJobObject"));
        }
        if ResumeThread(process.hThread) == u32::MAX {
            CloseHandle(job);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return Err(last_error("ResumeThread"));
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);

        let mut child_input = BufWriter::new(std::fs::File::from_raw_handle(parent_stdin_write));
        let child_output = BufReader::new(std::fs::File::from_raw_handle(parent_stdout_read));
        let (sender, receiver) = mpsc::sync_channel::<String>(8);
        std::thread::spawn(move || {
            for line in child_output.lines().map_while(Result::ok) {
                if line.len() <= MAX_MESSAGE_BYTES {
                    let _ = sender.send(line);
                }
            }
        });

        let stdin = io::stdin();
        let mut stdout = io::stdout().lock();
        for (index, line) in stdin.lock().lines().enumerate() {
            if index >= MAX_REQUESTS {
                write_error(&mut stdout, "Sandbox request limit exceeded")?;
                break;
            }
            let line = line.map_err(|error| error.to_string())?;
            if line.len() > MAX_MESSAGE_BYTES {
                write_error(&mut stdout, "Sandbox request is too large")?;
                continue;
            }
            child_input
                .write_all(line.as_bytes())
                .and_then(|_| child_input.write_all(b"\n"))
                .and_then(|_| child_input.flush())
                .map_err(|error| error.to_string())?;
            let mut last_output = String::new();
            let response = loop {
                let candidate = match receiver.recv_timeout(WALL_TIMEOUT) {
                    Ok(value) => value,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        return Err(format!(
                            "Sandbox step exceeded its wall-time limit{}",
                            if last_output.is_empty() {
                                String::new()
                            } else {
                                format!("; last runner output: {last_output}")
                            }
                        ));
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        return Err(format!(
                            "Sandbox runner exited{}",
                            if last_output.is_empty() {
                                String::new()
                            } else {
                                format!("; last runner output: {last_output}")
                            }
                        ));
                    }
                };
                if serde_json::from_str::<Value>(&candidate)
                    .ok()
                    .is_some_and(|value| value.get("status").is_some())
                {
                    break candidate;
                }
                if !last_output.is_empty() {
                    last_output.push_str(" | ");
                }
                last_output.push_str(&candidate);
                if last_output.len() > 4000 {
                    last_output.drain(..last_output.len() - 4000);
                }
            };
            stdout
                .write_all(response.as_bytes())
                .and_then(|_| stdout.write_all(b"\n"))
                .and_then(|_| stdout.flush())
                .map_err(|error| error.to_string())?;
        }
        CloseHandle(job);
        Ok(())
    }

    unsafe fn create_limited_job() -> Result<HANDLE, String> {
        let job = CreateJobObjectW(null(), null());
        if job.is_null() {
            return Err(last_error("CreateJobObjectW"));
        }
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            | JOB_OBJECT_LIMIT_ACTIVE_PROCESS
            | JOB_OBJECT_LIMIT_PROCESS_MEMORY
            | JOB_OBJECT_LIMIT_JOB_MEMORY
            | JOB_OBJECT_LIMIT_PROCESS_TIME
            | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        limits.BasicLimitInformation.ActiveProcessLimit = 1;
        limits.BasicLimitInformation.PerProcessUserTimeLimit = CPU_LIMIT_100NS;
        limits.ProcessMemoryLimit = MEMORY_LIMIT;
        limits.JobMemoryLimit = MEMORY_LIMIT;
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const c_void,
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) == 0
        {
            CloseHandle(job);
            return Err(last_error("SetInformationJobObject"));
        }
        Ok(job)
    }

    fn command_line(args: &Arguments, scratch: &Scratch) -> String {
        [
            quote(&scratch.executable),
            "--headless".to_string(),
            "--path".to_string(),
            quote(&scratch.project),
            "--script".to_string(),
            "res://runner.gd".to_string(),
            "--log-file".to_string(),
            quote(&scratch.root.join("godot.log")),
            "--".to_string(),
            "--package-root".to_string(),
            quote(&scratch.package),
            "--package-hash".to_string(),
            args.package_hash.clone(),
            "--nonce".to_string(),
            args.nonce.clone(),
        ]
        .join(" ")
    }

    fn quote(path: &Path) -> String {
        format!("\"{}\"", path.display().to_string().replace('"', "\\\""))
    }

    fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
        value.as_ref().encode_wide().chain(Some(0)).collect()
    }

    fn last_error(operation: &str) -> String {
        format!("{operation} failed: {}", io::Error::last_os_error())
    }

    fn write_error(output: &mut impl Write, message: &str) -> Result<(), String> {
        writeln!(
            output,
            "{}",
            serde_json::json!({"status": "error", "message": message})
        )
        .and_then(|_| output.flush())
        .map_err(|error| error.to_string())
    }
}

#[cfg(windows)]
fn main() {
    if let Err(message) = windows_host::run() {
        println!(
            "{}",
            serde_json::json!({"status": "error", "message": message})
        );
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("scenario-sandbox-host is supported only on Windows");
    std::process::exit(1);
}
