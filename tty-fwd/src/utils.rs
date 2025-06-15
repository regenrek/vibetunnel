use std::io;

/// Terminal dimensions
#[derive(Debug, Clone, Copy)]
pub struct TerminalSize {
    pub width: u16,
    pub height: u16,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self {
            width: 80,
            height: 24,
        }
    }
}

/// Get the current terminal size
///
/// Returns the actual terminal dimensions if available, otherwise returns default size (80x24)
pub fn terminal_size() -> TerminalSize {
    get_terminal_size().unwrap_or_default()
}

#[cfg(unix)]
fn get_terminal_size() -> Result<TerminalSize, io::Error> {
    use std::mem;
    use std::os::unix::io::AsRawFd;

    #[repr(C)]
    struct Winsize {
        ws_row: libc::c_ushort,
        ws_col: libc::c_ushort,
        ws_xpixel: libc::c_ushort,
        ws_ypixel: libc::c_ushort,
    }

    let mut winsize: Winsize = unsafe { mem::zeroed() };
    let ret = unsafe {
        libc::ioctl(
            io::stdout().as_raw_fd(),
            libc::TIOCGWINSZ,
            &mut winsize as *mut Winsize,
        )
    };

    if ret == 0 && winsize.ws_col > 0 && winsize.ws_row > 0 {
        Ok(TerminalSize {
            width: winsize.ws_col,
            height: winsize.ws_row,
        })
    } else {
        Err(io::Error::new(
            io::ErrorKind::Other,
            "Failed to get terminal size",
        ))
    }
}

#[cfg(windows)]
fn get_terminal_size() -> Result<TerminalSize, io::Error> {
    use windows_sys::Win32::System::Console::{
        GetConsoleScreenBufferInfo, GetStdHandle, CONSOLE_SCREEN_BUFFER_INFO, STD_OUTPUT_HANDLE,
    };

    unsafe {
        let handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if handle == 0 {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "Failed to get console handle",
            ));
        }

        let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
        if GetConsoleScreenBufferInfo(handle, &mut info) == 0 {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "Failed to get console screen buffer info",
            ));
        }

        let width = (info.srWindow.Right - info.srWindow.Left + 1) as u16;
        let height = (info.srWindow.Bottom - info.srWindow.Top + 1) as u16;

        if width > 0 && height > 0 {
            Ok(TerminalSize { width, height })
        } else {
            Err(io::Error::new(
                io::ErrorKind::Other,
                "Invalid terminal dimensions",
            ))
        }
    }
}
