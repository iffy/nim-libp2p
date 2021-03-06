## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements variable buffer.
import varint, strutils

type
  VBuffer* = object
    buffer*: seq[byte]
    offset*: int
    length*: int

template isEmpty*(vb: VBuffer): bool =
  ## Returns ``true`` if buffer ``vb`` is empty.
  len(vb.buffer) - vb.offset <= 0

template isEnough*(vb: VBuffer, length: int): bool =
  ## Returns ``true`` if buffer ``vb`` holds at least ``length`` bytes.
  len(vb.buffer) - vb.offset - length >= 0

proc len*(vb: VBuffer): int =
  ## Returns number of bytes left in buffer ``vb``.
  result = len(vb.buffer) - vb.offset

proc isLiteral[T](s: seq[T]): bool {.inline.} =
  type
    SeqHeader = object
      length, reserved: int
  (cast[ptr SeqHeader](s).reserved and (1 shl (sizeof(int) * 8 - 2))) != 0

proc initVBuffer*(data: seq[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with shallow copy of ``data``.
  if isLiteral(data):
    result.buffer = data
  else:
    shallowCopy(result.buffer, data)
  result.offset = offset

proc initVBuffer*(data: openarray[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with copy of ``data``.
  result.buffer = newSeq[byte](len(data))
  if len(data) > 0:
    copyMem(addr result.buffer[0], unsafeAddr data[0], len(data))
  result.offset = offset

proc initVBuffer*(): VBuffer =
  ## Initialize empty VBuffer.
  result.buffer = newSeqOfCap[byte](128)

proc writeVarint*(vb: var VBuffer, value: LPSomeUVarint) =
  ## Write ``value`` as variable unsigned integer.
  var length = 0
  # LibP2P varint supports only 63 bits.
  var v = value and cast[type(value)](0x7FFF_FFFF_FFFF_FFFF)
  vb.buffer.setLen(len(vb.buffer) + vsizeof(v))
  let res = LP.putUVarint(toOpenArray(vb.buffer, vb.offset, len(vb.buffer) - 1),
                          length, v)
  doAssert(res == VarintStatus.Success)
  vb.offset += length

proc writeSeq*[T: byte|char](vb: var VBuffer, value: openarray[T]) =
  ## Write array ``value`` to buffer ``vb``, value will be prefixed with
  ## varint length of the array.
  var length = 0
  vb.buffer.setLen(len(vb.buffer) + vsizeof(len(value)) + len(value))
  let res = LP.putUVarint(toOpenArray(vb.buffer, vb.offset, len(vb.buffer) - 1),
                          length, uint(len(value)))
  doAssert(res == VarintStatus.Success)
  vb.offset += length
  if len(value) > 0:
    copyMem(addr vb.buffer[vb.offset], unsafeAddr value[0], len(value))
    vb.offset += len(value)

proc writeArray*[T: byte|char](vb: var VBuffer, value: openarray[T]) =
  ## Write array ``value`` to buffer ``vb``, value will NOT be prefixed with
  ## varint length of the array.
  var length = 0
  if len(value) > 0:
    vb.buffer.setLen(len(vb.buffer) + len(value))
    copyMem(addr vb.buffer[vb.offset], unsafeAddr value[0], len(value))
    vb.offset += len(value)

proc finish*(vb: var VBuffer) =
  ## Finishes ``vb``.
  vb.offset = 0

proc peekVarint*(vb: var VBuffer, value: var LPSomeUVarint): int =
  ## Peek unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  result = -1
  value = cast[type(value)](0)
  var length = 0
  if not vb.isEmpty():
    let res = LP.getUVarint(
      toOpenArray(vb.buffer, vb.offset, len(vb.buffer) - 1), length, value)
    if res == VarintStatus.Success:
      result = length

proc peekSeq*[T: string|seq[byte]](vb: var VBuffer, value: var T): int =
  ## Peek length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  result = -1
  value.setLen(0)
  var length = 0
  var size = 0'u64
  if not vb.isEmpty() and
     LP.getUVarint(toOpenArray(vb.buffer, vb.offset, len(vb.buffer) - 1),
                   length, size) == VarintStatus.Success:
    vb.offset += length
    result = length
    if vb.isEnough(int(size)):
      value.setLen(size)
      if size > 0'u64:
        copyMem(addr value[0], addr vb.buffer[vb.offset], size)
      result += int(size)
    vb.offset -= length

proc peekArray*[T: char|byte](vb: var VBuffer,
                              value: var openarray[T]): int =
  ## Peek array from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  result = -1
  let length = len(value)
  if vb.isEnough(length):
    if length > 0:
      copyMem(addr value[0], addr vb.buffer[vb.offset], length)
    result = length

proc readVarint*(vb: var VBuffer, value: var LPSomeUVarint): int {.inline.} =
  ## Read unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  result = vb.peekVarint(value)
  if result != -1:
    vb.offset += result

proc readSeq*[T: string|seq[byte]](vb: var VBuffer,
                                   value: var T): int {.inline.} =
  ## Read length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  result = vb.peekSeq(value)
  if result != -1:
    vb.offset += result

proc readArray*[T: char|byte](vb: var VBuffer,
                              value: var openarray[T]): int {.inline.} =
  ## Read array from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  result = vb.peekArray(value)
  if result != -1:
    vb.offset += result

proc `$`*(vb: VBuffer): string =
  ## Return hexadecimal string representation of buffer ``vb``.
  let length = (len(vb.buffer) - vb.offset) * 2
  result = newStringOfCap(length)
  for i in 0..<len(vb.buffer):
    result.add(toHex(vb.buffer[i]))
