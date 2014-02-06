{ catch windows exceptions (mostly access violations) in your
  DLL and re-raise them as native FPC exceptions. This uunit
  works only on windows XP or later and only on 32 bit. This
  unit is public domain. (c) 2010 Bernd Kreuss }

unit profs_win32exceptiontrap;

{$mode objfpc}

interface

var
  ThisModuleHandle: THandle;
  ThisModuleName: array[0..1000] of char;

implementation

uses
  Windows, SysUtils;

var
  ExceptionHandlerRefCount: Integer = 0;
  ExHandle: Pointer;

threadvar
  ExObject : EExternal;

function AddVectoredExceptionHandler(FirstHandler: DWORD; VectoredHandler: pointer): pointer; stdcall; external 'kernel32.dll' name 'AddVectoredExceptionHandler';
function RemoveVectoredExceptionHandler(VectoredHandlerHandle: pointer): ULONG; stdcall; external 'kernel32.dll' name 'RemoveVectoredExceptionHandler';

function GetModuleByAddr(addr: pointer): THandle;
var
  Tmm: TMemoryBasicInformation;
begin
  if VirtualQuery(addr, @Tmm, SizeOf(Tmm)) <> sizeof(Tmm)
    then Result := 0
    {$hints off}
    else Result := THandle(Tmm.AllocationBase);
    {$hints on}
end;

function ExceptionHandler(Info: PEXCEPTION_POINTERS): LongInt; stdcall;
var
  ExCode : DWORD;
  ExAddr : Pointer;
  ExModule : THandle;
label
  lblRaise;
begin
  ExCode := Info^.ExceptionRecord^.ExceptionCode;
  if ExCode = $40010006 then // ignore debug print
    exit(EXCEPTION_CONTINUE_SEARCH);

  ExAddr := Info^.ExceptionRecord^.ExceptionAddress;
  ExModule := GetModuleByAddr(ExAddr);

  // did it happen in the same module where this handler resides?
  if ExModule = ThisModuleHandle then begin

    // after preparing a native FPC exception object we will clear the
    // Windows exception and manipulate the CPU instruction pointer to point
    // exactly to the place where it will be raised with raise so it can
    // then be properly caught by except. We can't just raise it directly
    // from here because we are inside the Windows exception handler and
    // windows expects this function to return and for Windows the exception
    // is already finished when our FPC try/raise/except mechanism starts.
    ExObject := EExternal.Create(Format('Exception %x at %p', [ExCode, ExAddr]));
    {$hints off}
    Info^.ContextRecord^.Eip := PtrUInt(@lblRaise);
    {$hints on}
    exit(EXCEPTION_CONTINUE_EXECUTION);

  end else begin

    // this exception happened somewhere else, we might not be able to handle it,
    // so we will pass it on to the next handler but we still print a message
    // because it might at least be interesting to know about it for debugging.
    OutputDebugString(PChar(Format('exception %x at %p in %s -> EXCEPTION_CONTINUE_SEARCH', [ExCode, ExAddr, GetModuleName(ExModule)])));
    exit(EXCEPTION_CONTINUE_SEARCH);
  end;

  // the following will never be reached *during* this function call,
  // instead it will be jumped to and executed *after* the handler has
  // returned and windows restarts execution at the new position of eip.
  lblRaise:
  Raise ExObject; // this can be caught with try/except
end;

procedure InstallExceptionHandler;
begin
  ExHandle := AddVectoredExceptionHandler(1, @ExceptionHandler);
  OutputDebugString(PChar(Format('installed exception handler for %s', [ThisModuleName])));
end;

procedure RemoveExceptionHandler;
var
  // we don't have automatic strings and stuff during unload anymore,
  // so we have to use the stack for our little good-bye message
  msg: array[0..1000] of char;
begin
  RemoveVectoredExceptionHandler(ExHandle);
  strlcopy(msg, 'removed exception handler for ', 1000);
  strlcat(msg, ThisModuleName, 1000);
  OutputDebugString(msg);
end;

initialization
  // most non-FPC and non-Borland apps do not want FPU exceptions
  // (they might crash) so we immediately undo FPC's FPU unmasking.
  Set8087CW(Get8087CW or $3f);
  ThisModuleHandle := GetModuleByAddr(@ExceptionHandler);
  GetModuleFileName(ThisModuleHandle, ThisModuleName, 1000);
  InstallExceptionHandler;
finalization
  RemoveExceptionHandler;
end.

