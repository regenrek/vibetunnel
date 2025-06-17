use std::ffi::CString;

use anyhow::Result;
use uuid::Uuid;

#[cfg(target_os = "macos")]
use objc2::{class, msg_send, runtime::AnyObject};

pub fn spawn_terminal_command(command: &[String], working_dir: Option<&str>) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();

    unsafe {
        // Get NSDistributedNotificationCenter class
        let notification_center_class = class!(NSDistributedNotificationCenter);
        let notification_center: *mut AnyObject =
            msg_send![notification_center_class, defaultCenter];

        // Create notification name
        let notification_name_str = CString::new("sh.vibetunnel.vibetunnel.spawn")?;
        let nsstring_class = class!(NSString);
        let notification_name: *mut AnyObject =
            msg_send![nsstring_class, stringWithUTF8String: notification_name_str.as_ptr()];

        // Create NSArray for command arguments
        let nsarray_class = class!(NSArray);
        let mut command_objects = Vec::new();
        for arg in command {
            let arg_cstr = CString::new(arg.as_str())?;
            let arg_nsstring: *mut AnyObject =
                msg_send![nsstring_class, stringWithUTF8String: arg_cstr.as_ptr()];
            command_objects.push(arg_nsstring);
        }
        let command_array: *mut AnyObject = msg_send![
            nsarray_class,
            arrayWithObjects: command_objects.as_ptr()
            count: command_objects.len()
        ];

        // Create session ID NSString
        let session_id_cstr = CString::new(session_id.clone())?;
        let session_id_nsstring: *mut AnyObject =
            msg_send![nsstring_class, stringWithUTF8String: session_id_cstr.as_ptr()];

        // Create dictionary keys
        let command_key_cstr = CString::new("command")?;
        let command_key: *mut AnyObject =
            msg_send![nsstring_class, stringWithUTF8String: command_key_cstr.as_ptr()];

        let session_id_key_cstr = CString::new("sessionId")?;
        let session_id_key: *mut AnyObject =
            msg_send![nsstring_class, stringWithUTF8String: session_id_key_cstr.as_ptr()];

        // Create NSDictionary
        let nsdict_class = class!(NSDictionary);
        let user_info: *mut AnyObject = if let Some(wd) = working_dir {
            // Create working directory NSString
            let working_dir_cstr = CString::new(wd)?;
            let working_dir_nsstring: *mut AnyObject =
                msg_send![nsstring_class, stringWithUTF8String: working_dir_cstr.as_ptr()];

            let working_dir_key_cstr = CString::new("workingDir")?;
            let working_dir_key: *mut AnyObject =
                msg_send![nsstring_class, stringWithUTF8String: working_dir_key_cstr.as_ptr()];

            let keys = vec![command_key, session_id_key, working_dir_key];
            let values = vec![command_array, session_id_nsstring, working_dir_nsstring];
            msg_send![
                nsdict_class,
                dictionaryWithObjects: values.as_ptr()
                forKeys: keys.as_ptr()
                count: keys.len()
            ]
        } else {
            let keys = vec![command_key, session_id_key];
            let values = vec![command_array, session_id_nsstring];
            msg_send![
                nsdict_class,
                dictionaryWithObjects: values.as_ptr()
                forKeys: keys.as_ptr()
                count: keys.len()
            ]
        };

        // Post notification
        let _: () = msg_send![
            notification_center,
            postNotificationName: notification_name
            object: std::ptr::null::<AnyObject>()
            userInfo: user_info
        ];

        println!(
            "Sent terminal spawn notification for session: {}",
            session_id
        );
    }

    Ok(session_id)
}
