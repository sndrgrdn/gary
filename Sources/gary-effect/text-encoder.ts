const replacement = 0xfffd;

function encodeCodePoint(code: number, bytes: number[]): void {
  if (code < 0x80) {
    bytes.push(code);
  } else if (code < 0x800) {
    bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
  } else if (code < 0x10000) {
    bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
  } else {
    bytes.push(
      0xf0 | (code >> 18),
      0x80 | ((code >> 12) & 63),
      0x80 | ((code >> 6) & 63),
      0x80 | (code & 63),
    );
  }
}

class TextEncoder {
  readonly encoding = "utf-8";

  encode(input = ""): Uint8Array {
    const bytes: number[] = [];

    for (const char of input) {
      const code = char.codePointAt(0) ?? replacement;
      encodeCodePoint(code >= 0xd800 && code <= 0xdfff ? replacement : code, bytes);
    }

    return new Uint8Array(bytes);
  }
}

Object.assign(globalThis, { TextEncoder });
