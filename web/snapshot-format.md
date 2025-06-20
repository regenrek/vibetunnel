# VibeTunnel Terminal Buffer Snapshot Format

This document describes the binary format used for efficient terminal buffer snapshots.

## Overview

The snapshot format is a compact binary representation of terminal buffer state, designed to minimize data transfer while preserving all terminal attributes. It consists of a header followed by a stream of encoded cells.

## Format Structure

```
┌──────────────┬─────────────────────────────────┐
│    Header    │         Cell Stream             │
│   (32 bytes) │    (variable, 4+ bytes/cell)   │
└──────────────┴─────────────────────────────────┘
```

## Header Format (32 bytes) - Version 2

```
Offset  Size  Field         Description
------  ----  ----------    -----------
0x00    2     Magic         0x5654 ("VT" in ASCII)
0x02    1     Version       Format version (0x02 for 32-bit support)
0x03    1     Flags         Reserved for future use
0x04    4     Cols          Terminal width (32-bit unsigned, little-endian)
0x08    4     Rows          Number of rows in this snapshot (32-bit unsigned, little-endian)
0x0C    4     ViewportY     Starting line number in buffer (32-bit signed, little-endian)
0x10    4     CursorX       Cursor column position (32-bit signed, little-endian)
0x14    4     CursorY       Cursor row position relative to viewport (32-bit signed, little-endian)
0x18    4     Reserved      Reserved for future use
```

Note: CursorY is relative to the viewport and can be negative if the cursor is above the visible area.

## Cell Format

Each cell uses a variable-length encoding:

### Basic Cell (4 bytes) - ASCII with palette colors

```
Offset  Size  Field         Description
------  ----  ----------    -----------
0x00    1     Character     UTF-8 character (ASCII range)
0x01    1     Attributes    Bit flags (see below)
0x02    1     FG Color      Foreground palette index (0-255)
0x03    1     BG Color      Background palette index (0-255)
```

### Extended Cell (variable) - Unicode or RGB colors

```
Offset  Size  Field         Description
------  ----  ----------    -----------
0x00    1     Header        [2 bits: char_len-1][1 bit: rgb_fg][1 bit: rgb_bg][4 bits: reserved]
0x01    1     Attributes    Bit flags (see below)
0x02    1-4   Character     UTF-8 character (length from header)
0x??    1/3   FG Color      1 byte palette or 3 bytes RGB
0x??    1/3   BG Color      1 byte palette or 3 bytes RGB
```

### Attribute Flags (1 byte)

```
Bit  Flag
---  ----
0    Bold
1    Italic
2    Underline
3    Dim
4    Inverse
5    Invisible
6    Strikethrough
7    Extended (if set, use extended cell format)
```

## Special Encodings

### Run-Length Encoding

For repeated cells (common with spaces), use RLE:

```
0xFF <count:1> <cell:4+>
```

This encodes up to 255 repeated cells.

### Empty Line Marker

For completely empty lines (all spaces with default attributes):

```
0xFE <count:1>
```

This encodes up to 255 empty lines.

## Color Encoding

### Palette Colors (0-255)
Standard xterm 256-color palette indices.

### RGB Colors (24-bit)
When RGB flag is set in extended cell header:
```
R (1 byte) G (1 byte) B (1 byte)
```

## API Endpoint

### Request
```
GET /api/sessions/{sessionId}/buffer?viewportY={Y}&lines={N}
```

Parameters:
- `sessionId`: Session identifier
- `viewportY`: Starting line in the terminal buffer (0-based)
- `lines`: Number of lines to return

### Response
```
Content-Type: application/octet-stream
Content-Length: {size}

[Binary data as described above]
```

## Example

For a 80x24 terminal showing "Hello" on black background:

```
Header (32 bytes):
56 54 02 00  50 00 00 00  18 00 00 00  00 00 00 00  05 00 00 00  00 00 00 00  00 00 00 00
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   └─┴─┴─┴─ Reserved
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   └─┴─┴─┴─ CursorY (0)
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   └─┴─┴─┴─ CursorX (5)
│  │  │  │   │  │  │  │   │  │  │  │   └─┴─┴─┴─ ViewportY (0)
│  │  │  │   │  │  │  │   └─┴─┴─┴─ Rows (24)
│  │  │  │   └─┴─┴─┴─ Cols (80)
│  │  │  └─ Flags (0)
│  │  └─ Version (2)
└─┴─ Magic "VT"

Cells:
48 00 07 00  65 00 07 00  6C 00 07 00  6C 00 07 00  6F 00 07 00
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  │  └─ BG: black (0)
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  │  └─ FG: white (7)
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   │  └─ Attributes: none (0)
│  │  │  │   │  │  │  │   │  │  │  │   │  │  │  │   └─ Character: 'o'
[Continue for remaining cells...]

FF 4B 20 00 07 00  (RLE: 75 spaces)
FE 17              (23 empty lines)
```

## Implementation Notes

1. The server maintains xterm.js Terminal instances for each active session
2. Binary encoding happens on-the-fly when buffer endpoint is called
3. Client can request specific viewport regions for efficient updates
4. Format is designed to be easily parseable with minimal overhead
5. Extended format allows for future enhancements without breaking compatibility

## Performance Characteristics

- Basic ASCII terminal: ~4 bytes per cell
- With colors/attributes: ~4-7 bytes per cell  
- With RLE compression: ~10-20% of original size for typical terminals
- Network transfer: ~3-8KB for full 80x24 screen (before gzip)