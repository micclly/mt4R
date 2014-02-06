{ MT4 -> R interface library -- start Rterm processes and interact with them

  Copyright (C) 2010 Bernd Kreuss <prof7bit@googlemail.com>

  This source is free software; you can redistribute it and/or modify it
  under the terms of the GNU General Public License as published by the Free
  Software Foundation; either version 2 of the License, or (at your option)
  any later version.

  This code is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
  more details.

  A copy of the GNU General Public License is available on the World Wide
  Web at <http://www.gnu.org/copyleft/gpl.html>. You can also obtain it by
  writing to the Free Software Foundation, Inc., 59 Temple Place - Suite
  330, Boston, MA 02111-1307, USA.

  A commercial license and support is available upon request
}
library mt4R;

{$mode objfpc}{$H+}

uses
  cmem,
  Classes,
  Windows,
  SysUtils,
  profs_win32exceptiontrap,
  profs_TRConsole;

{internal helper functions}

// log a message to the debug monitor
procedure Log(AMessage: String);
begin
  OutputDebugString(PChar(AMessage));
end;

// log a formatted message to the debug monitor
procedure Log(AMessage: String; AArgs: array of const);
begin
  Log(Format(AMessage, AArgs));
end;

// return true if the R session object belonging to the handle is valid
function isValid(AHandle: LongInt): Boolean;
var
  Dummy: Boolean;
begin
  try
    // cast the "handle" back into the pointer that it was
    // and then just try to access some field
    Dummy  := TRConsole(AHandle).Running;
    Result := True;
  except
    // if invalid this should have raised an access violation
    Log('Invalid (not existing) handle for TRConsole object: %d', [AHandle]);
    Dummy  := Dummy; // suppress the compiler hint about unused variable
    Result := False;
  end;
end;

{:Converts Unicode string to Ansi string using specified code page.
  @param   ws       Unicode string.
  @param   codePage Code page to be used in conversion.
  @returns Converted ansi string.
}

function WideStringToString(const ws: WideString; codePage: Word): AnsiString;
var
  l: integer;
begin
  if ws = '' then
    Result := ''
  else
  begin
    l := WideCharToMultiByte(codePage,
      WC_COMPOSITECHECK or WC_DISCARDNS or WC_SEPCHARS or WC_DEFAULTCHAR,
      @ws[1], - 1, nil, 0, nil, nil);
    SetLength(Result, l - 1);
    if l > 1 then
      WideCharToMultiByte(codePage,
        WC_COMPOSITECHECK or WC_DISCARDNS or WC_SEPCHARS or WC_DEFAULTCHAR,
        @ws[1], - 1, @Result[1], l - 1, nil, nil);
  end;
end;

{ exported functions. These functions are the API that is used by MQL4 }

// get the DLL version (only major and minor)
function RGetDllVersion: LongInt; stdcall;
begin
  Result := GetFileVersion(ThisModuleName);
end;

 // start a new R session and return the handle. The "handle" is actually
 // a pointer cast to a LongInt (32 bit) and in mql4 it can be treated like
 // a handle. The other functions will simply cast it back into TRConsole.
function RInit_(ACommandLine: PWideChar; ADebugLevel: LongInt): LongInt; stdcall;
var
  R: TRConsole;
begin
  getversion;
  R      := TRConsole.Create(WideStringToString(ACommandLine, CP_ACP), ADebugLevel);
  Result := Longint(R);
  Log('RInit: RHandle = %x (%d)', [Result, Result]);
end;

// terminate the R session
procedure RDeinit(AHandle: LongInt); stdcall;
begin
  Log('RDeinit: RHandle = %x (%d)', [AHandle, AHandle]);
  if isValid(AHandle) then
    TRConsole(AHandle).Free;
end;

// is the R session still running? (it will terminate on any error)
function RIsRunning(AHandle: LongInt): Longbool; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).Running
  else
    Result := False;
end;

// last executed code (use this when logging R crash)
function RLastCode(AHandle: LongInt): PChar; stdcall;
begin
  if isValid(AHandle) then
    Result := PChar(TRConsole(AHandle).LastCode)
  else
    Result := '';
end;

// last known raw output of the session (use this when logging R crash)
function RLastOutput(AHandle: LongInt): PChar; stdcall;
begin
  if isValid(AHandle) then
    Result := PChar(TRConsole(AHandle).LastOutput)
  else
    Result := '';
end;

 // return true if R is executing a command. This might happen
 // when a prior call to RExecuteAsync() has not yet finished
function RIsBusy(AHandle: LongInt): Longbool; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).Busy
  else
    Result := True; // a non-existing console is regarded as busy.
end;

// execute code and wait
procedure RExecute(AHandle: LongInt; ACode: PWideChar); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).ExecuteCode(WideStringToString(ACode, CP_ACP));
end;

 // execute code and do not wait. You should use IsBusy to
 // check whether it is finished. Subsequent calls will
 // inevitably block and wait until R is free again.
procedure RExecuteAsync(AHandle: LongInt; ACode: PWideChar); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).ExecuteCodeAsync(WideStringToString(ACode, CP_ACP));
end;

// assign bool to variable given by name
procedure RAssignBool(AHandle: LongInt; AVariable: PWideChar; AValue: Longbool); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignBoolean(WideStringToString(AVariable, CP_ACP), AValue);
end;

// assign integer to variable given by name
procedure RAssignInteger(AHandle: LongInt; AVariable: PWideChar; AValue: LongInt); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignInteger(WideStringToString(AVariable, CP_ACP), AValue);
end;

// assign double to variable given by name
procedure RAssignDouble(AHandle: LongInt; AVariable: PWideChar; AValue: Double); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignDouble(WideStringToString(AVariable, CP_ACP), AValue);
end;

// assign string to variable given by name
procedure RAssignString(AHandle: LongInt; AVariable: PWideChar; AValue: PChar); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignString(WideStringToString(AVariable, CP_ACP), AValue);
end;

// assign vector to variable given by name
procedure RAssignVector(AHandle: LongInt; AVariable: PWideChar; AVector: PVector; ASize: LongInt); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignVector(WideStringToString(AVariable, CP_ACP), AVector, ASize);
end;

// assign vector of strings to variable given by name
procedure RAssignStringVector(AHandle: LongInt; AVariable: PWideChar; AVector: PStrVector; ASize: LongInt); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignStringVector(WideStringToString(AVariable, CP_ACP), AVector, ASize);
end;

// assign a matrix to the variable give by name
procedure RAssignMatrix(AHandle: LongInt; AVariable: PWideChar; AMatrix: PVector; ARows: LongInt; ACols: LongInt); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AssignMatrix(WideStringToString(AVariable, CP_ACP), AMatrix, ARows, ACols);
end;

// variable <- rbind(variable, vector)
procedure RAppendMatrixRow(AHandle: LongInt; AVariable: PWideChar; AVector: PVector; ASize: LongInt); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).AppendMatrixRow(WideStringToString(AVariable, CP_ACP), AVector, ASize);
end;

// evaluate expression and return integer
function RExists(AHandle: LongInt; AVariable: PWideChar): Longbool; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).Exists(WideStringToString(AVariable, CP_ACP))
  else
    Result := False;
end;

// evaluate expression and return boolean
function RGetBool(AHandle: LongInt; AExpression: PChar): Longbool; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).GetBoolean(AExpression)
  else
    Result := False;
end;

// evaluate expression and return integer
function RGetInteger(AHandle: LongInt; AExpression: PChar): LongInt; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).GetInteger(AExpression)
  else
    Result := 0;
end;

// evaluate expression and return double
function RGetDouble(AHandle: LongInt; AExpression: PWideChar): Double; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).GetDouble(WideStringToString(AExpression, CP_ACP))
  else
    Result := 0;
end;

 // evaluate expression and return vector into supplied array.
 // Return value is the actual number of elements that have been copied.
 // if the size of the array does not match the size of the actuall vector
 // then a warning will be emitted on debuglevel 1. Return value will
 // always be equal or smaller than the supplied ASize.
function RGetVector(AHandle: LongInt; AExpression: PWideChar; AVector: PVector; ASize: LongInt): LongInt; stdcall;
begin
  if isValid(AHandle) then
    Result := TRConsole(AHandle).GetVector(WideStringToString(AExpression, CP_ACP), AVector, ASize)
  else
    Result := 0;
end;

// call print() and show the output on debuglevel 0
procedure RPrint(AHandle: LongInt; AExpression: PWideChar); stdcall;
begin
  if isValid(AHandle) then
    TRConsole(AHandle).Print(WideStringToString(AExpression, CP_ACP));
end;

exports
  RGetDllVersion,
  RInit_,
  RDeinit,
  RIsRunning,
  RLastCode,
  RLastOutput,
  RIsBusy,
  RExecute,
  RExecuteAsync,
  RAssignBool,
  RAssignInteger,
  RAssignDouble,
  RAssignString,
  RAssignVector,
  RAssignStringVector,
  RAssignMatrix,
  RAppendMatrixRow,
  RExists,
  RGetBool,
  RGetInteger,
  RGetDouble,
  RGetVector,
  RPrint;

{$R *.res}

begin
end.

