## Effect Algebra: the user-facing API for composing effectful computations.
##
## Eff[T] is a typed wrapper around EffProgram. The builder API
## (pure, fail, andThen, map, perform, handle) constructs the
## defunctionalized continuation table.
##
## App developers use this module. They do NOT see TruthValue.

import ./core
import ./vm/types

type
  EffBase* = ref object of RootObj
    ## Type-erased base for Eff, enabling boxing via RootRef.
    program*: EffProgram

  Eff*[T] = ref object of EffBase
    ## A description of an effectful computation producing T.
    ## Lazy: nothing executes until the runner interprets the program.
    boxer*: proc(v: T): BoxedValue {.gcsafe.}
    unboxer*: proc(v: BoxedValue): T {.gcsafe.}

  HandlerProc* = proc(payload: BoxedValue,
                       resume: proc(v: BoxedValue) {.gcsafe.},
                       abort: proc(e: RtError) {.gcsafe.}) {.gcsafe, closure.}

# --- Generic boxing helpers ---

proc defaultBoxer[T](v: T): BoxedValue =
  when T is int:
    boxInt(v)
  elif T is string:
    boxStr(v)
  elif T is float:
    boxFloat(v)
  elif T is bool:
    boxBool(v)
  elif T is ref:
    boxRef(v)
  elif T is ValidationIssueDetail:
    boxIssue(v)
  else:
    boxNone()

proc defaultUnboxer[T](v: BoxedValue): T =
  when T is int:
    unboxInt(v)
  elif T is string:
    unboxStr(v)
  elif T is float:
    unboxFloat(v)
  elif T is bool:
    unboxBool(v)
  elif T is ref:
    if v.kind == bvRef and not v.refVal.isNil:
      if v.refVal of T:
        cast[T](v.refVal)
      else:
        # Internal type mismatch — fail fast instead of returning nil
        raise newException(Defect, "Internal unboxing error: ref type mismatch")
    elif v.kind == bvNone:
      # Explicitly allow nil for bvNone if T is a ref type
      nil
    else:
      # Other kinds (int, string etc.) should not be unboxed as ref
      raise newException(Defect, "Internal unboxing error: non-ref kind for ref type")
  elif T is ValidationIssueDetail:
    if v.kind == bvValidationIssue:
      v.issueVal
    else:
      default(T)
  else:
    default(T)

# --- Constructors ---

proc pure*[T](v: T): Eff[T] =
  ## Immediate success with value v.
  result = Eff[T](
    program: EffProgram(),
    boxer: defaultBoxer[T],
    unboxer: defaultUnboxer[T],
  )
  let id = result.program.addOp(EffOp(kind: opPure, pureValue: defaultBoxer(v)))
  result.program.entry = id

proc fail*[T](e: RtError): Eff[T] =
  ## Immediate failure with error e.
  result = Eff[T](
    program: EffProgram(),
    boxer: defaultBoxer[T],
    unboxer: defaultUnboxer[T],
  )
  let id = result.program.addOp(EffOp(kind: opFail, failError: e))
  result.program.entry = id

proc perform*[T](tag: EffectTag, payload: BoxedValue = boxNone()): Eff[T] =
  ## Request an effect identified by tag.
  result = Eff[T](
    program: EffProgram(),
    boxer: defaultBoxer[T],
    unboxer: defaultUnboxer[T],
  )
  let id = result.program.addOp(EffOp(kind: opPerform,
    performTag: tag,
    performPayload: payload,
  ))
  result.program.entry = id

# --- Composition ---

proc mergeProgram(target: var EffProgram, source: EffProgram): ContId =
  ## Copy all ops from source into target, returning the remapped entry.
  let offset = target.ops.len
  for op in source.ops:
    var remapped = op
    case remapped.kind
    of opPure, opFail, opPerform:
      discard
    of opBind:
      remapped.bindSource = ContId(remapped.bindSource.int + offset)
      remapped.bindNext = ContId(remapped.bindNext.int + offset)
    of opMap:
      remapped.mapTarget = ContId(remapped.mapTarget.int + offset)
    of opHandle:
      remapped.handleBody = ContId(remapped.handleBody.int + offset)
    target.ops.add(remapped)
  ContId(source.entry.int + offset)

proc andThen*[T, U](eff: Eff[T], f: proc(v: T): Eff[U] {.gcsafe.}): Eff[U] =
  ## Monadic bind: run eff, pass result to f, run resulting Eff[U].
  result = Eff[U](
    program: EffProgram(),
    boxer: defaultBoxer[U],
    unboxer: defaultUnboxer[U],
  )
  # Copy source program
  let sourceEntry = mergeProgram(result.program, eff.program)

  # Create a placeholder continuation (opMap that calls f and returns inner program)
  # For now, we use opBind with a dynamically created continuation
  let capturedF = f
  let capturedUnboxer = eff.unboxer
  let capturedResultUnboxer = defaultUnboxer[U]

  # Add a map-like node that invokes f and returns a bvProgram
  let nextId = result.program.addOp(EffOp(kind: opMap,
    mapTarget: ContId(-1), # Result is provided by opBind, no target evaluation needed
    mapFn: proc(v: BoxedValue): BoxedValue {.gcsafe.} =
      # At interpretation time, f(unbox(v)) produces an Eff[U]
      let innerEff = capturedF(capturedUnboxer(v))
      # Pack the inner program for the engine (no circular import needed)
      BoxedValue(kind: bvProgram,
        innerProgram: innerEff.program,
        innerUnboxer: proc(bv: BoxedValue): BoxedValue {.gcsafe.} =
          defaultBoxer(capturedResultUnboxer(bv)),
      ),
  ))

  # The entry is a bind: run source, then continuation
  let entryId = result.program.addOp(EffOp(kind: opBind,
    bindSource: sourceEntry,
    bindNext: nextId,
  ))
  result.program.entry = entryId

proc map*[T, U](eff: Eff[T], f: proc(v: T): U {.gcsafe.}): Eff[U] =
  ## Functor map: transform the value without introducing new effects.
  result = Eff[U](
    program: EffProgram(),
    boxer: defaultBoxer[U],
    unboxer: defaultUnboxer[U],
  )
  let sourceEntry = mergeProgram(result.program, eff.program)
  let capturedF = f
  let capturedUnboxer = eff.unboxer
  let mapId = result.program.addOp(EffOp(kind: opMap,
    mapTarget: sourceEntry,
    mapFn: proc(v: BoxedValue): BoxedValue {.gcsafe.} =
      defaultBoxer(capturedF(capturedUnboxer(v))),
  ))
  result.program.entry = mapId

proc handle*[T](eff: Eff[T], tag: EffectTag, h: HandlerProc): Eff[T] =
  ## Install an effect handler for the given tag around eff.
  result = Eff[T](
    program: EffProgram(),
    boxer: eff.boxer,
    unboxer: eff.unboxer,
  )
  let bodyEntry = mergeProgram(result.program, eff.program)
  let handleId = result.program.addOp(EffOp(kind: opHandle,
    handleBody: bodyEntry,
    handleTag: tag,
    handleImpl: h,
  ))
  result.program.entry = handleId
