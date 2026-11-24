use std::io::{self, Read, Write};

pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

#[derive(Debug, PartialEq)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub body: Vec<u8>,
}

#[derive(Debug)]
pub enum HttpError {
    TooLarge,
    Malformed,
    #[allow(dead_code)]
    // the wrapped error is available to callers but not read inside this module
    Io(io::Error),
}

impl From<io::Error> for HttpError {
    fn from(e: io::Error) -> Self {
        HttpError::Io(e)
    }
}

/// Returns `true` once the byte slice contains the end-of-headers marker.
fn headers_complete(request: &[u8]) -> bool {
    request.windows(4).any(|window| window == b"\r\n\r\n")
}

/// Returns `(method, path)` from the first line of a completed HTTP request.
/// Strips query strings from the path, mirroring the reference demo.
fn request_target(request: &[u8]) -> Option<(&str, &str)> {
    let request_line_end = request.windows(2).position(|w| w == b"\r\n")?;
    let request_line = std::str::from_utf8(request.get(..request_line_end)?).ok()?;
    let mut fields = request_line.split_whitespace();
    let method = fields.next()?;
    let target = fields.next()?;
    let version = fields.next()?;

    if fields.next().is_some() || !version.starts_with("HTTP/") {
        return None;
    }

    Some((method, target.split('?').next()?))
}

/// Read a full HTTP request (headers + body) from `r`.
///
/// Returns `Ok(None)` on a clean EOF before the header terminator arrives.
/// Returns `Err(HttpError::TooLarge)` when headers or headers+body exceed
/// `MAX_REQUEST_BYTES`. Returns `Err(HttpError::Malformed)` on bad syntax or
/// a PUT/POST request without a `Content-Length` header.
pub fn read_request<R: Read>(r: &mut R) -> Result<Option<Request>, HttpError> {
    // --- Phase 1: accumulate bytes until \r\n\r\n ---
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];

    loop {
        if headers_complete(&buf) {
            break;
        }
        let remaining = MAX_REQUEST_BYTES.saturating_sub(buf.len());
        if remaining == 0 {
            return Err(HttpError::TooLarge);
        }
        let read_limit = remaining.min(chunk.len());
        let bytes_read = r.read(&mut chunk[..read_limit]).map_err(HttpError::Io)?;
        if bytes_read == 0 {
            // Clean EOF before headers completed
            return Ok(None);
        }
        buf.extend_from_slice(&chunk[..bytes_read]);
    }

    // --- Phase 2: parse request line ---
    let (method_ref, path_ref) = request_target(&buf).ok_or(HttpError::Malformed)?;
    let method = method_ref.to_owned();
    let path = path_ref.to_owned();

    // --- Phase 3: locate end of headers ---
    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or(HttpError::Malformed)?;

    let header_section = std::str::from_utf8(buf.get(..header_end).ok_or(HttpError::Malformed)?)
        .map_err(|_| HttpError::Malformed)?;

    // --- Phase 4: find Content-Length (case-insensitive) ---
    let content_length: Option<usize> = header_section
        .lines()
        .skip(1) // skip the request line
        .find_map(|line| {
            let colon = line.find(':')?;
            let name = line.get(..colon)?.trim();
            if name.eq_ignore_ascii_case("content-length") {
                line.get(colon + 1..)?.trim().parse().ok()
            } else {
                None
            }
        });

    // --- Phase 5: read body ---
    let body = match content_length {
        Some(len) => {
            // Guard: headers + body must fit within MAX_REQUEST_BYTES
            let total = (header_end + 4).saturating_add(len);
            if total > MAX_REQUEST_BYTES {
                return Err(HttpError::TooLarge);
            }

            // Some body bytes may have been pulled in with the headers; take at most
            // `len` of them so that pipelined or adversarial extra bytes are excluded.
            let after_headers = buf.get(header_end + 4..).unwrap_or_default();
            // ponytail: unwrap_or_default is safe — header_end + 4 <= buf.len() by
            // construction (headers_complete was true when we broke out of the read loop)
            let take = after_headers.len().min(len);
            let mut body = after_headers.get(..take).unwrap_or_default().to_vec();
            // ponytail: take <= after_headers.len(), so get(..take) is always Some
            let need = len - take;
            if need > 0 {
                let old_len = body.len();
                body.resize(old_len + need, 0);
                r.read_exact(body.get_mut(old_len..).ok_or(HttpError::Malformed)?)
                    .map_err(HttpError::Io)?;
            }
            body
        }
        None => {
            // PUT and POST require a body; reject if no Content-Length present.
            if method == "PUT" || method == "POST" {
                return Err(HttpError::Malformed);
            }
            Vec::new()
        }
    };

    Ok(Some(Request { method, path, body }))
}

/// Write a minimal HTTP/1.1 response.
pub fn write_response<W: Write>(
    w: &mut W,
    status: u16,
    reason: &str,
    content_type: &str,
    body: &[u8],
) -> io::Result<()> {
    write!(
        w,
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n",
        body.len()
    )?;
    w.write_all(body)?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::{HttpError, MAX_REQUEST_BYTES, read_request, write_response};
    use std::io::Cursor;

    #[allow(clippy::unwrap_used)]
    #[test]
    fn reads_put_with_body() {
        let mut input = Cursor::new(b"PUT /decrypt HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc");
        let req = read_request(&mut input).unwrap().unwrap();
        assert_eq!(req.method, "PUT");
        assert_eq!(req.path, "/decrypt");
        assert_eq!(req.body, b"abc");
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn rejects_body_over_limit() {
        let header = b"PUT /decrypt HTTP/1.1\r\nContent-Length: 70000\r\n\r\n";
        let mut input = Cursor::new(header.to_vec());
        let err = read_request(&mut input).unwrap_err();
        assert!(matches!(err, HttpError::TooLarge));
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn rejects_oversized_headers() {
        let mut input = Cursor::new(vec![b'a'; MAX_REQUEST_BYTES]);
        let err = read_request(&mut input).unwrap_err();
        assert!(matches!(err, HttpError::TooLarge));
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn rejects_missing_content_length_on_put() {
        let mut input = Cursor::new(b"PUT /decrypt HTTP/1.1\r\nHost: localhost\r\n\r\n");
        let err = read_request(&mut input).unwrap_err();
        assert!(matches!(err, HttpError::Malformed));
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn eof_before_headers_is_none() {
        let mut input = Cursor::new(b"GET / HT");
        let result = read_request(&mut input).unwrap();
        assert!(result.is_none());
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn body_truncated_to_content_length() {
        // Extra bytes after the declared body must be ignored.
        let mut input =
            Cursor::new(b"PUT /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcEXTRA".to_vec());
        let req = read_request(&mut input).unwrap().unwrap();
        assert_eq!(req.body, b"abc");
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn zero_content_length_with_trailing_bytes() {
        // Content-Length: 0 means no body, even if bytes follow.
        let mut input = Cursor::new(b"GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra".to_vec());
        let req = read_request(&mut input).unwrap().unwrap();
        assert_eq!(req.body, b"");
    }

    #[allow(clippy::unwrap_used)]
    #[test]
    fn write_response_sets_length() {
        let mut out = Vec::new();
        write_response(&mut out, 200, "OK", "text/plain", b"hi").unwrap();
        let s = String::from_utf8_lossy(&out);
        assert!(
            s.starts_with("HTTP/1.1 200 OK\r\n"),
            "unexpected start: {s}"
        );
        assert!(
            s.contains("Content-Length: 2\r\n"),
            "missing Content-Length: {s}"
        );
        assert!(s.contains("Connection: close"), "missing Connection: {s}");
    }
}
