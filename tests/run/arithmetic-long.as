let main() -> {
    let c: int32 = 0x10101010;
    assert(c + c * 2 // 3 * 2 + (c - 7 % 3) ==
           c + c * 2 // 3 * 2 + (c - 7 % 3));
}
