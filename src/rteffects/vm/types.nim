## VM types: defunctionalized continuation table.
##
## EffProgram is a flat sequence of EffOp entries linked by ContId.
## The VM engine interprets this structure as a state machine.

import std/hashes
import ../core

type
  ContId* = distinct int
    ## Index into EffProgram.ops

  EffectTag* = distinct string
    ## Identifies an effect for handler dispatch

  # --- Boxing for type-erased values ---

  BoxedValueKind* = enum
    bvNone, bvInt, bvStr, bvFloat, bvBool, bvRef, bvProgram, bvValidationIssue

  BoxedValue* = object
    ## Type-erased value for the continuation table.
    case kind*: BoxedValueKind
    of bvNone: discard
    of bvInt: intVal*: int
    of bvStr: strVal*: string
    of bvFloat: floatVal*: float
    of bvBool: boolVal*: bool
    of bvRef: refVal*: RootRef
    of bvValidationIssue: issueVal*: ValidationIssueDetail
    of bvProgram:
      innerProgram*: EffProgram  ## Nested program from andThen
      innerUnboxer*: proc(v: BoxedValue): BoxedValue {.gcsafe.}

  # --- Continuation table operations ---

  EffOpKind* = enum
    opPure       ## Return a value
    opFail       ## Return an error
    opBind       ## Sequence: run source, pass result to next
    opMap        ## Transform current value with a function
    opPerform    ## Request effect handling
    opHandle     ## Install effect handler scope

  EffOp* = object
    case kind*: EffOpKind
    of opPure:
      pureValue*: BoxedValue
    of opFail:
      failError*: RtError
    of opBind:
      bindSource*: ContId   ## Run this first
      bindNext*: ContId     ## Then continue here with result
    of opMap:
      mapTarget*: ContId
      mapFn*: proc(v: BoxedValue): BoxedValue {.gcsafe, closure.}
    of opPerform:
      performTag*: EffectTag
      performPayload*: BoxedValue
    of opHandle:
      handleBody*: ContId
      handleTag*: EffectTag
      handleImpl*: proc(payload: BoxedValue,
                        resume: proc(v: BoxedValue) {.gcsafe.},
                        abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}

  EffProgram* = object
    ## A computation as a flat sequence of operations.
    ops*: seq[EffOp]
    entry*: ContId

const
  ValidationTag* = EffectTag("Validation")

# --- ContId operations ---

proc `==`*(a, b: ContId): bool {.borrow.}
proc hash*(a: ContId): Hash {.borrow.}
proc `$`*(a: ContId): string =
  "ContId(" & $a.int & ")"

# --- EffectTag operations ---

proc `==`*(a, b: EffectTag): bool {.borrow.}
proc hash*(a: EffectTag): Hash {.borrow.}
proc `$`*(a: EffectTag): string {.borrow.}

# --- BoxedValue constructors ---

proc boxInt*(v: int): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvInt, intVal: v)

proc boxStr*(v: string): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvStr, strVal: v)

proc boxFloat*(v: float): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvFloat, floatVal: v)

proc boxBool*(v: bool): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvBool, boolVal: v)

proc boxRef*(v: RootRef): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvRef, refVal: v)

proc boxIssue*(v: ValidationIssueDetail): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvValidationIssue, issueVal: v)

proc boxNone*(): BoxedValue {.raises: [].} =
  BoxedValue(kind: bvNone)

proc unboxInt*(v: BoxedValue): int {.raises: [].} =
  v.intVal

proc unboxStr*(v: BoxedValue): string {.raises: [].} =
  v.strVal

proc unboxFloat*(v: BoxedValue): float {.raises: [].} =
  v.floatVal

proc unboxBool*(v: BoxedValue): bool {.raises: [].} =
  v.boolVal

proc unboxIssue*(v: BoxedValue): ValidationIssueDetail {.raises: [].} =
  v.issueVal

# --- EffProgram builder helpers ---

proc addOp*(prog: var EffProgram, op: EffOp): ContId =
  ## Add an operation and return its ContId.
  result = ContId(prog.ops.len)
  prog.ops.add(op)
