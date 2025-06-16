use std::ops::Deref;
use std::ops::DerefMut;

use bytes::BytesMut;
pub use http::*;
use io::Read;
use io::Write;
use std::io;
use std::net::SocketAddr;
use std::net::TcpListener;
use std::net::TcpStream;
use std::net::ToSocketAddrs;

#[derive(Debug)]
pub struct HttpServer {
    listener: TcpListener,
    request_size_limit: Option<usize>,
}

impl HttpServer {
    pub fn bind<A: ToSocketAddrs>(
        addr: A,
    ) -> std::result::Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let listener = TcpListener::bind(addr)?;
        Ok(Self {
            listener,
            request_size_limit: Some(4096),
        })
    }

    pub fn set_request_size_limit(&mut self, limit: Option<usize>) {
        self.request_size_limit = limit;
    }

    pub fn incoming(&self) -> Incoming {
        Incoming {
            listener: &self.listener,
            request_size_limit: self.request_size_limit,
        }
    }
}

#[derive(Debug)]
pub struct Incoming<'a> {
    listener: &'a TcpListener,
    request_size_limit: Option<usize>,
}

impl<'a> Iterator for Incoming<'a> {
    type Item = std::result::Result<HttpRequest, Box<dyn std::error::Error + Send + Sync>>;

    fn next(&mut self) -> Option<Self::Item> {
        match self.listener.accept() {
            Ok((stream, remote_addr)) => Some(HttpRequest::from_stream(
                stream,
                remote_addr,
                self.request_size_limit,
            )),
            Err(e) => Some(Err(Box::new(e))),
        }
    }
}

#[derive(Debug)]
pub struct HttpRequest {
    stream: TcpStream,
    remote_addr: SocketAddr,
    request: Request<Vec<u8>>,
}

impl HttpRequest {
    fn from_stream(
        mut stream: TcpStream,
        remote_addr: SocketAddr,
        request_size_limit: Option<usize>,
    ) -> std::result::Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let mut buffer = BytesMut::new();
        let mut tmp = [0; 1024];

        loop {
            match stream.read(&mut tmp) {
                Ok(0) => {
                    return Err("Connection closed by client".into());
                }
                Ok(n) => {
                    buffer.extend_from_slice(&tmp[..n]);

                    if let Some(limit) = request_size_limit {
                        if buffer.len() > limit {
                            return Err("Request too large".into());
                        }
                    }

                    if let Some(header_end) = find_header_end(&buffer) {
                        let header_bytes = &buffer[..header_end];
                        let body_start = header_end + 4; // Skip \r\n\r\n

                        let request_line_end = header_bytes
                            .windows(2)
                            .position(|w| w == b"\r\n")
                            .ok_or("Invalid request line")?;

                        let request_line = std::str::from_utf8(&header_bytes[..request_line_end])?;
                        let mut parts = request_line.split_whitespace();
                        let method = parts.next().ok_or("Missing method")?;
                        let uri = parts.next().ok_or("Missing URI")?;
                        let version = parts.next().unwrap_or("HTTP/1.1");

                        let method = method.parse::<Method>()?;
                        let uri = uri.parse::<Uri>()?;
                        let version = match version {
                            "HTTP/1.0" => Version::HTTP_10,
                            "HTTP/1.1" => Version::HTTP_11,
                            _ => return Err("Unsupported HTTP version".into()),
                        };

                        let mut request_builder =
                            Request::builder().method(method).uri(uri).version(version);

                        let headers_start = request_line_end + 2;
                        let headers_bytes = &header_bytes[headers_start..];

                        for header_line in headers_bytes.split(|&b| b == b'\n') {
                            if header_line.is_empty() || header_line == b"\r" {
                                continue;
                            }

                            let header_line = if header_line.ends_with(b"\r") {
                                &header_line[..header_line.len() - 1]
                            } else {
                                header_line
                            };

                            if let Some(colon_pos) = header_line.iter().position(|&b| b == b':') {
                                let name = std::str::from_utf8(&header_line[..colon_pos])?.trim();
                                let value =
                                    std::str::from_utf8(&header_line[colon_pos + 1..])?.trim();
                                request_builder = request_builder.header(name, value);
                            }
                        }

                        let content_length = request_builder
                            .headers_ref()
                            .and_then(|h| h.get("content-length"))
                            .and_then(|v| v.to_str().ok())
                            .and_then(|s| s.parse::<usize>().ok());

                        let mut body = Vec::new();
                        if let Some(content_length) = content_length {
                            if content_length > 0 {
                                let mut bytes_read = 0;
                                if body_start < buffer.len() {
                                    let available =
                                        std::cmp::min(content_length, buffer.len() - body_start);
                                    body.extend_from_slice(
                                        &buffer[body_start..body_start + available],
                                    );
                                    bytes_read = available;
                                }

                                while bytes_read < content_length {
                                    let remaining = content_length - bytes_read;
                                    let to_read = std::cmp::min(remaining, tmp.len());
                                    match stream.read(&mut tmp[..to_read]) {
                                        Ok(0) => break,
                                        Ok(n) => {
                                            body.extend_from_slice(&tmp[..n]);
                                            bytes_read += n;
                                        }
                                        Err(e) => return Err(Box::new(e)),
                                    }
                                }
                            }
                        }

                        let request = request_builder.body(body)?;

                        return Ok(HttpRequest {
                            stream,
                            remote_addr,
                            request,
                        });
                    }
                }
                Err(e) => return Err(Box::new(e)),
            }
        }
    }

    pub fn remote_addr(&self) -> SocketAddr {
        self.remote_addr
    }

    pub fn respond<T: AsRef<[u8]>>(
        &mut self,
        response: T,
    ) -> std::result::Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.stream.write_all(response.as_ref())?;
        self.stream.flush()?;
        Ok(())
    }
}

impl Deref for HttpRequest {
    type Target = Request<Vec<u8>>;

    fn deref(&self) -> &Self::Target {
        &self.request
    }
}

impl DerefMut for HttpRequest {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.request
    }
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|w| w == b"\r\n\r\n")
}
