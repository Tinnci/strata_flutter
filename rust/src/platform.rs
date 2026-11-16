#[cfg(windows)]
mod imp {
    use crate::api::scan::{ScanNodeData, VolumeSummary};
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::path::Path;
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        FindClose, FindExInfoBasic, FindExSearchNameMatch, FindFirstFileExW, FindNextFileW,
        GetDiskFreeSpaceExW, GetDriveTypeW, GetLogicalDriveStringsW, GetVolumeInformationW,
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FIND_FIRST_EX_LARGE_FETCH,
        WIN32_FIND_DATAW,
    };
    use windows_sys::Win32::UI::Shell::{
        SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT,
        FO_DELETE, SHFILEOPSTRUCTW,
    };

    const DRIVE_FIXED: u32 = 3;
    const DRIVE_REMOVABLE: u32 = 2;

    fn to_wide_null(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    pub fn list_volumes() -> Vec<VolumeSummary> {
        let mut buf = [0u16; 512];
        let len = unsafe { GetLogicalDriveStringsW(buf.len() as u32, buf.as_mut_ptr()) } as usize;
        if len == 0 {
            return Vec::new();
        }

        let sys_drive = std::env::var("SystemDrive")
            .unwrap_or_else(|_| "C:".to_string())
            .to_uppercase();

        let mut volumes = Vec::new();
        let mut start = 0;
        while start < len {
            let end = buf[start..len]
                .iter()
                .position(|&c| c == 0)
                .map(|p| start + p)
                .unwrap_or(len);
            if end == start {
                break;
            }
            let drive_slice = &buf[start..=end];
            let mount = OsString::from_wide(&buf[start..end])
                .to_string_lossy()
                .into_owned();
            start = end + 1;

            let drive_type = unsafe { GetDriveTypeW(drive_slice.as_ptr()) };
            if drive_type != DRIVE_FIXED && drive_type != DRIVE_REMOVABLE {
                continue;
            }

            let mut total_bytes: u64 = 0;
            let mut available_bytes: u64 = 0;
            let ok_space = unsafe {
                GetDiskFreeSpaceExW(
                    drive_slice.as_ptr(),
                    &mut available_bytes,
                    &mut total_bytes,
                    std::ptr::null_mut(),
                )
            };
            if ok_space == 0 || total_bytes == 0 {
                continue;
            }

            let mut vol_name = [0u16; 256];
            let ok_info = unsafe {
                GetVolumeInformationW(
                    drive_slice.as_ptr(),
                    vol_name.as_mut_ptr(),
                    vol_name.len() as u32,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    0,
                )
            };

            let label = if ok_info != 0 {
                let nlen = vol_name.iter().position(|&c| c == 0).unwrap_or(0);
                OsString::from_wide(&vol_name[..nlen])
                    .to_string_lossy()
                    .into_owned()
            } else {
                String::new()
            };

            let clean_letter = mount.trim_end_matches('\\');
            let is_system_drive = clean_letter.eq_ignore_ascii_case(&sys_drive);
            let display_name = if label.is_empty() {
                format!("Local Disk ({clean_letter})")
            } else {
                format!("{label} ({clean_letter})")
            };

            volumes.push(VolumeSummary {
                name: display_name,
                mount_point: mount,
                total_bytes,
                available_bytes,
                is_system_drive,
            });
        }
        volumes
    }

    pub fn scan_recursive<F: FnMut(&[ScanNodeData], u64, u64)>(
        dir: &Path,
        parent_id: u32,
        prune_below_bytes: u64,
        nodes: &mut Vec<ScanNodeData>,
        entry_count: &mut u64,
        scanned_bytes: &mut u64,
        on_progress: &mut F,
    ) {
        let mut pattern = dir.as_os_str().encode_wide().collect::<Vec<u16>>();
        if !pattern.ends_with(&['\\' as u16]) {
            pattern.push('\\' as u16);
        }
        pattern.push('*' as u16);
        pattern.push(0);

        let mut data: WIN32_FIND_DATAW = unsafe { std::mem::zeroed() };
        let handle: HANDLE = unsafe {
            FindFirstFileExW(
                pattern.as_ptr(),
                FindExInfoBasic,
                &mut data as *mut _ as *mut _,
                FindExSearchNameMatch,
                std::ptr::null_mut(),
                FIND_FIRST_EX_LARGE_FETCH,
            )
        };

        if handle == INVALID_HANDLE_VALUE {
            return;
        }

        let mut small_bytes: u64 = 0;
        let mut small_count: u32 = 0;
        let top_ancestor = find_top_ancestor(nodes, parent_id);

        loop {
            let name_len = data
                .cFileName
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(data.cFileName.len());
            let name = OsString::from_wide(&data.cFileName[..name_len])
                .to_string_lossy()
                .into_owned();

            if name != "." && name != ".." {
                *entry_count += 1;
                let attrs = data.dwFileAttributes;
                let is_reparse = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                let is_dir = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;

                if !is_reparse {
                    if is_dir {
                        let child_id = nodes.len() as u32;
                        nodes.push(ScanNodeData {
                            id: child_id,
                            parent: Some(parent_id),
                            name: name.clone(),
                            size: 0,
                            is_dir: true,
                            is_small_group: false,
                            item_count: 1,
                            children: Vec::new(),
                        });
                        nodes[parent_id as usize].children.push(child_id);
                        let sub_path = dir.join(&name);
                        scan_recursive(
                            &sub_path,
                            child_id,
                            prune_below_bytes,
                            nodes,
                            entry_count,
                            scanned_bytes,
                            on_progress,
                        );
                    } else {
                        let size =
                            ((data.nFileSizeHigh as u64) << 32) | (data.nFileSizeLow as u64);
                        *scanned_bytes = scanned_bytes.saturating_add(size);
                        if let Some(top_id) = top_ancestor {
                            nodes[top_id as usize].size =
                                nodes[top_id as usize].size.saturating_add(size);
                        }
                        if size < prune_below_bytes {
                            small_bytes = small_bytes.saturating_add(size);
                            small_count = small_count.saturating_add(1);
                        } else {
                            let child_id = nodes.len() as u32;
                            nodes.push(ScanNodeData {
                                id: child_id,
                                parent: Some(parent_id),
                                name,
                                size,
                                is_dir: false,
                                is_small_group: false,
                                item_count: 1,
                                children: Vec::new(),
                            });
                            nodes[parent_id as usize].children.push(child_id);
                        }
                    }
                }

                if (*entry_count & 0xFF) == 0 {
                    on_progress(nodes, *entry_count, *scanned_bytes);
                }
            }

            let next = unsafe { FindNextFileW(handle, &mut data) };
            if next == 0 {
                break;
            }
        }

        unsafe { FindClose(handle) };

        if small_bytes > 0 {
            let group_id = nodes.len() as u32;
            nodes.push(ScanNodeData {
                id: group_id,
                parent: Some(parent_id),
                name: String::new(),
                size: small_bytes,
                is_dir: false,
                is_small_group: true,
                item_count: small_count,
                children: Vec::new(),
            });
            nodes[parent_id as usize].children.push(group_id);
        }
    }

    fn find_top_ancestor(nodes: &[ScanNodeData], mut id: u32) -> Option<u32> {
        if id == 0 {
            return None;
        }
        while let Some(p) = nodes[id as usize].parent {
            if p == 0 {
                return Some(id);
            }
            id = p;
        }
        None
    }

    pub fn move_to_trash(path: &str) -> Result<(), String> {
        let mut wide = to_wide_null(path);
        wide.push(0); // Double null-terminated.
        let mut op = SHFILEOPSTRUCTW {
            hwnd: std::ptr::null_mut(),
            wFunc: FO_DELETE,
            pFrom: wide.as_ptr(),
            pTo: std::ptr::null(),
            fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT) as u16,
            fAnyOperationsAborted: 0,
            hNameMappings: std::ptr::null_mut(),
            lpszProgressTitle: std::ptr::null(),
        };
        let res = unsafe { SHFileOperationW(&mut op) };
        if res == 0 && op.fAnyOperationsAborted == 0 {
            Ok(())
        } else {
            Err(format!("SHFileOperationW failed with code {res}"))
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use crate::api::scan::{ScanNodeData, VolumeSummary};
    use std::fs;
    use std::path::Path;

    pub fn list_volumes() -> Vec<VolumeSummary> {
        vec![VolumeSummary {
            name: "/".to_string(),
            mount_point: "/".to_string(),
            total_bytes: 0,
            available_bytes: 0,
            is_system_drive: true,
        }]
    }

    pub fn scan_recursive<F: FnMut(&[ScanNodeData], u64, u64)>(
        dir: &Path,
        parent_id: u32,
        prune_below_bytes: u64,
        nodes: &mut Vec<ScanNodeData>,
        entry_count: &mut u64,
        scanned_bytes: &mut u64,
        on_progress: &mut F,
    ) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        let mut small_bytes: u64 = 0;
        let mut small_count: u32 = 0;

        for entry in entries.flatten() {
            *entry_count += 1;
            let Ok(meta) = entry.symlink_metadata() else {
                continue;
            };
            if meta.file_type().is_symlink() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if meta.is_dir() {
                let child_id = nodes.len() as u32;
                nodes.push(ScanNodeData {
                    id: child_id,
                    parent: Some(parent_id),
                    name,
                    size: 0,
                    is_dir: true,
                    is_small_group: false,
                    item_count: 1,
                    children: Vec::new(),
                });
                nodes[parent_id as usize].children.push(child_id);
                scan_recursive(
                    &entry.path(),
                    child_id,
                    prune_below_bytes,
                    nodes,
                    entry_count,
                    scanned_bytes,
                    on_progress,
                );
            } else {
                let size = meta.len();
                *scanned_bytes = scanned_bytes.saturating_add(size);
                if size < prune_below_bytes {
                    small_bytes = small_bytes.saturating_add(size);
                    small_count = small_count.saturating_add(1);
                } else {
                    let child_id = nodes.len() as u32;
                    nodes.push(ScanNodeData {
                        id: child_id,
                        parent: Some(parent_id),
                        name,
                        size,
                        is_dir: false,
                        is_small_group: false,
                        item_count: 1,
                        children: Vec::new(),
                    });
                    nodes[parent_id as usize].children.push(child_id);
                }
            }
            if (*entry_count & 0xFF) == 0 {
                on_progress(nodes, *entry_count, *scanned_bytes);
            }
        }

        if small_bytes > 0 {
            let group_id = nodes.len() as u32;
            nodes.push(ScanNodeData {
                id: group_id,
                parent: Some(parent_id),
                name: String::new(),
                size: small_bytes,
                is_dir: false,
                is_small_group: true,
                item_count: small_count,
                children: Vec::new(),
            });
            nodes[parent_id as usize].children.push(group_id);
        }
    }

    pub fn move_to_trash(_path: &str) -> Result<(), String> {
        Err("Trash not yet implemented on this platform".to_string())
    }
}

pub use imp::{list_volumes, move_to_trash, scan_recursive};
