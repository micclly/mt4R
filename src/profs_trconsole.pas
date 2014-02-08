{ TRConsole is a class for wrapping a running R (rterm) process

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
unit profs_TRConsole;

{$mode objfpc}{$H+}

interface

uses
  process,
  Classes;

type
  // this is double foo[] in mql4
  TVector = array [0..maxLongint div SizeOf(Double) - 1] of Double;
  PVector = ^TVector;

  TMqlStr = packed record
    Size: LongInt;
    Ptr:  PWideChar;
    Dummy: LongInt;
  end;

  // this is string foo[] in mql4.
  TStrVector = array [0..maxLongint div SizeOf(TMqlStr) - 1] of TMqlStr;
  PStrVector = ^TStrVector;

  { TRconsole represents an instance of an R console running in the background}
  TRConsole = class(TProcess)
  protected
    FDebugLevel:      Integer;
    FLastCode:        Ansistring; // last executed code (for error message after crash)
    FLastOutput:      Ansistring;
    FBusy:            Boolean;
    FBusyWaitCrtSect: TRTLCriticalSection;
    FStopping:        Boolean;
    procedure Msg(ALevel: Integer; AMethod: Ansistring; AMessage: Ansistring);
    procedure Msg(ALevel: Integer; AMethod: Ansistring; AMessage: Ansistring; AArgs: array of const);
    function GetOutput: Ansistring;
    function ConvertDouble(AStr: Ansistring): Double;
    procedure WaitNotBusy;
    procedure SetNotBusy;
  public
    // start an instance of R (c:\full\path\to\Rterm.exe --no-save)
    constructor Create(ACommandLine: Ansistring; ADebugLevel: LongInt); reintroduce;

    // stop the R session. Call this before Free
    procedure Stop;

    // terminate the R session (don't call this, call Free as usual)
    destructor Destroy; override;

    // is R just executing a command?
    property Busy: Boolean read FBusy;

    // DebugLevel: 0=errors, 1=warnings, 2=all
    property DebugLevel: Integer read FDebugLevel write FDebugLevel;

    // Last executed code (for final crash error message)
    property LastCode: Ansistring read FLastCode;

    // Last seen R Output (for final crash error message)
    property LastOutput: Ansistring read FLastOutput;

    // print() the expression on debuglevel 0
    procedure Print(AExpression: Ansistring);

    // evaluate expression and return the raw output
    function ExecuteCode(ACode: Ansistring): Ansistring;

    // evaluate expression in a separate thread and
    // return immediately. This will aquire a lock,
    // any subsequent call will wait. Use IsBusy to
    // see whether it is still running.
    procedure ExecuteCodeAsync(ACode: Ansistring);

    // assign the boolean value to the variable
    procedure AssignBoolean(AVariable: Ansistring; AValue: Boolean);

    // assign the integer value to the variable
    procedure AssignInteger(AVariable: Ansistring; AValue: LongInt);

    // assign the double value to the variable
    procedure AssignDouble(AVariable: Ansistring; AValue: Double);

    // assign the string to the variable
    procedure AssignString(AVariable: Ansistring; AValue: Ansistring);

    // assign the vector to the variable
    procedure AssignVector(AVariable: Ansistring; AVector: PVector; ASize: LongInt);

    // assign the factor to the variable
    procedure AssignStringVector(AVariable: Ansistring; AVector: PStrVector; ASize: LongInt);

    // assign the matrix to the variable.
    // AMatrix is a pointer to the raw 2d array of doubles, first dimenstion is row.
    procedure AssignMatrix(AVariable: Ansistring; AMatrix: PVector; ARows: LongInt; ACols: LongInt);

    // append the vector as a new row to the variable
    procedure AppendMatrixRow(AVariable: Ansistring; AVector: PVector; ASize: LongInt);

    // return True if the variable exists
    function Exists(AVariable: Ansistring): Boolean;

    // evaluate expression and return boolean
    function GetBoolean(ACode: Ansistring): Boolean;

    // evaluate expression and return an integer
    function GetInteger(ACode: Ansistring): LongInt;

    // evaluate expression and retun a double
    function GetDouble(ACode: Ansistring): Double;

    // evaluate expression and return an array of double
    // and the number of elements that were actually copied.
    // the supplied array must be big enough or it will not copy
    // all elements. The ACode must evaluate to a vector.
    function GetVector(ACode: Ansistring; AVector: PVector; ASize: LongInt): LongInt;

  end;

  { TAsyncExecute is the thread that will be started by ExecuteCodeAsync() and
  will wait for the command to end. It will then release the lock again and end. }
  TAsyncExecute = class(TThread)
  protected
    FConsole: TRConsole;
    FCode:    Ansistring;
  public
    constructor Create(AConsole: TRConsole; ACode: Ansistring); reintroduce;
    procedure Execute; override;
  end;

  { This thread will be started for every TRConsole instance to keep
  the plot window alive. R will only process window events for the
  plot windows if there is some action on the command line. Therefore
  we will execute an empty string (equivalent of pressing enter) every
  200 milliseconds. This will avoid freezing of the plot windows.}
  TPlotEventLoop = class(TThread)
  protected
    FConsole: TRConsole;
  public
    constructor Create(AConsole: TRConsole); reintroduce;
    procedure Execute; override;
  end;


implementation

uses
  {$ifdef win32}Windows,{$endif}
  SysUtils,
  strutils,
  Math,
  stringutil;

resourcestring
  rsCouldNotFormatDebugMessage = 'could not format debug message';
  rsDebugStoppingR = 'Stopping R';
  rsDebugSuccessfulStart = 'R successfully started';
  rsDebugTryingToStartR = 'trying to start R: %s';
  rsDidNotQuitMustKill = 'did not quit, killing Rterm now';
  rsErrArraySize = 'Error: array size mismatch';
  rsErrCouldNotConvertDouble = 'Error: Could not convert to double: %s';
  rsErrCouldNotConvertToInt = 'Error: Could not convert to int: %s';
  rsErrDidNotStart = 'Error: R did not start: %d';
  rsErrRNotRunning = 'Error: R is not running (anymore): %s';
  rsErrWriteTemp = 'Error writing to temp file';
  rsNoteArrayBiggerThanNeeded = 'Note: array [%d] was bigger than really needed [%d]';
  rsSendingQuit = 'sending quit()';
  rsStartingSeparateThread = 'starting separate thread';
  rsStillBusyMustKill = 'still executing another command, killing Rterm';
  rsWarnArrayTooSmall = 'Warning: array [%d] not big enough [%d], vector truncated';
  rsWarnBusyMustWait = 'Warning: R is busy, must wait...';
  rsWarnNA      = 'Warning: Expression returned NA';
  rsWarnNull    = 'Warning: Expression returned NULL';
  rsWritingData = 'writing data';


constructor TRConsole.Create(ACommandLine: Ansistring; ADebugLevel: LongInt);
begin
  inherited Create(nil);
  DecimalSeparator := '.';
  InitializeCriticalSection(FBusyWaitCrtSect);
  FDebugLevel := ADebugLevel;
  CommandLine := ACommandLine;
  Options     := [poUsePipes, poStderrToOutPut, poNoConsole, poNewProcessGroup];
  Msg(2, 'Create', Format(rsDebugTryingToStartR, [ACommandLine]));
  FStopping := False;
  try
    Execute;
  except
    on e:Exception do
      Msg(0, 'Create', e.Message);
  end;
  if Running then
  begin
    SetNotBusy;
    GetOutput;
    ExecuteCode('options(digits=15)');
    TPlotEventLoop.Create(self);
    Msg(2, 'Create', rsDebugSuccessfulStart);
  end else
  begin
    Msg(0, 'Create', Format(rsErrDidNotStart, [GetLastOSError]));
  end;
end;

procedure TRConsole.Stop;
var
  Code: Ansistring = 'quit("no", 0, FALSE)' + LineEnding;
begin
  Msg(2, 'Stop', rsDebugStoppingR);
  if Running then
  begin
    if FBusy then
    begin // FIXME: find a way to send SIGINT and then quit()
      Msg(2, 'Stop', rsStillBusyMustKill);
      Terminate(0);
      Sleep(500);     // allow our ExecuteAsync thread to end
    end else
    begin
      Msg(2, 'Stop', rsSendingQuit);
      FLastCode := Code;
      Input.WriteBuffer(Code[1], Length(Code));
      Sleep(500);
      if Running then
      begin
        Msg(2, 'Stop', rsDidNotQuitMustKill);
        Terminate(0);
        Sleep(500);
      end;
    end;
  end;
end;

destructor TRconsole.Destroy;
begin
  FStopping := True;
  if Running then
    Stop;
  DeleteCriticalSection(FBusyWaitCrtSect);
  Msg(-1, 'TRConsole', 'destroying');
  inherited Destroy;
end;

procedure TRConsole.WaitNotBusy;
var
  GotTheLock:    Boolean;
  WarnedAlready: Boolean;
begin
  GotTheLock    := False;
  WarnedAlready := False;

  repeat
    EnterCriticalSection(FBusyWaitCrtSect);
    if FBusy = False then
    begin
      FBusy      := True;
      GotTheLock := True;
    end;
    LeaveCriticalSection(FBusyWaitCrtSect);

    if not GotTheLock then
    begin
      if not WarnedAlready then
      begin
        Msg(1, 'WaitNotBusy', rsWarnBusyMustWait);
        WarnedAlready := True;
      end;
      Sleep(10);
    end;
  until GotTheLock or not Running or FStopping;
end;

procedure TRConsole.SetNotBusy;
begin
  FBusy := False;
end;

procedure TRconsole.Msg(ALevel: Integer; AMethod: Ansistring; AMessage: Ansistring);
begin
  if ALevel <= FDebugLevel then
  begin
    AMessage := '<' + IntToStr(ALevel) + '> ' + AMethod + ': ' + AMessage;
    {$ifdef win32}
    OutputDebugString(PChar(AMessage));
    {$else}
    writeln(AMessage);
    {$endif}
  end;
end;

procedure TRConsole.Msg(ALevel: Integer; AMethod: Ansistring; AMessage: Ansistring; AArgs: array of const);
begin
  if ALevel <= FDebugLevel then
  begin
    try
      Msg(ALevel, AMethod, Format(AMessage, AArgs));
    except
      Msg(ALevel, AMethod, rsCouldNotFormatDebugMessage);
    end;
  end;
end;

function TRconsole.GetOutput: Ansistring;
const
  RPrompt = '> ';
var
  BytesRead: DWord;
  Position:  DWord;
  NumAvail:  DWord;
  b:         Char = #0;
begin
  Result   := '';
  Position := 0;
  while True do
  begin

    // blocking read one byte or 0 if crashed
    try
      if Output.Read(b, 1) = 0 then
      begin
        Msg(0, 'GetOutput', rsErrRNotRunning, [FLastCode]);
        Msg(0, 'GetOutput', rsErrRNotRunning, [Result]);
        FDebugLevel := -1; // no more messages. It just crashed, its over.
        exit;
      end;
    except
      Msg(0, 'GetOutput', rsErrRNotRunning, [FLastCode]);
      Msg(0, 'GetOutput', rsErrRNotRunning, [Result]);
      FDebugLevel := -1; // no more messages. It just crashed, its over.
      exit;
    end;

    Result   := Result + b;
    Position += 1;

    // now read the rest
    NumAvail := Output.NumBytesAvailable;
    if NumAvail > 0 then
    begin
      SetLength(Result, Position + NumAvail);
      BytesRead := Output.Read(Result[Position + 1], NumAvail);
      Position  := Position + BytesRead;

      // if we have a prompt then we are done, otherwise there
      // MUST be more data (we continue to wait for 1 byte or a crash)
      if RightStr(Result, Length(RPrompt)) = RPrompt then
      begin
        Result := LeftStr(Result, Length(Result) - Length(RPrompt));
        break;
      end;
      FLastOutput := Result;
    end;
  end;
end;

function TRconsole.ConvertDouble(AStr: Ansistring): Double;
begin
  if AStr = 'Inf' then
    exit(Infinity);
  if AStr = '-Inf' then
    exit(NegInfinity);
  if AStr = 'NaN' then
    exit(NaN);
  if AStr = 'NA' then
    exit(0);
  try
    Result := StrToFloat(AStr);
  except
    Msg(0, 'ConvertDouble', rsErrCouldNotConvertDouble, [AStr]);
    Result := 0;
  end;
end;

procedure TRConsole.Print(AExpression: Ansistring);
begin
  if Running then
    Msg(0, 'Print', 'print(' + AExpression + ')' + LineEnding + ExecuteCode('print(' + AExpression + ')'));
end;

function TRconsole.ExecuteCode(ACode: Ansistring): Ansistring;
begin
  Result := '';
  if not Running then
    exit;
  WaitNotBusy;
  if not Running then
    exit;
  FLastCode := ACode;
  Msg(2, 'ExecuteCode', 'in  >>>  ' + ACode);
  ACode := ACode + LineEnding;
  Input.Write(ACode[1], Length(ACode));
  Result := Trim(GetOutput);
  Result := RightStr(Result, Length(Result) - Length(ACode)); // remove echo
  Msg(2, 'ExecuteCode', 'out <<<  ' + Result);
  SetNotBusy;
end;

procedure TRConsole.ExecuteCodeAsync(ACode: Ansistring);
begin
  if not Running then
    exit;
  WaitNotBusy;
  if not Running then
    exit;
  Msg(2, 'ExecuteCodeAsync', rsStartingSeparateThread);
  TAsyncExecute.Create(self, ACode);
end;

procedure TRConsole.AssignBoolean(AVariable: Ansistring; AValue: Boolean);
begin
  if AValue then
    ExecuteCode(AVariable + ' <- TRUE')
  else
    ExecuteCode(AVariable + ' <- FALSE');
end;

procedure TRConsole.AssignInteger(AVariable: Ansistring; AValue: LongInt);
begin
  ExecuteCode(Format('%s <- %d', [AVariable, AValue]));
end;

procedure TRConsole.AssignDouble(AVariable: Ansistring; AValue: Double);
begin
  ExecuteCode(Format('%s <- %g', [AVariable, AValue]));
end;

procedure TRConsole.AssignString(AVariable: Ansistring; AValue: Ansistring);
begin
  ExecuteCode(Format('%s <- "%s"', [AVariable, AValue]));
end;

procedure TRConsole.AssignVector(AVariable: Ansistring; AVector: PVector; ASize: LongInt);
var
  Code:  Ansistring;
  i:     LongInt;
  Dummy: Double;
begin
  if not Running then
    exit;

  try
    Dummy := AVector^[ASize - 1];
  except
    Dummy := Dummy; // suppress compiler note
    Msg(0, 'AssignVector', rsErrArraySize);
    exit;
  end;

  Code := AVariable + ' <- c(';
  for i := 0 to ASize - 1 do
  begin
    Code := Code + FloatToStr(AVector^[i]) + ', ';
    if length(Code) > 3000 then
    begin // it does not like too long lines
      Code := LeftStr(Code, Length(Code) - 2) + ')'; // remove last ', '
      ExecuteCode(Code);
      Code := AVariable + ' <- c(' + AVariable + ', ';
    end;
  end;
  Code := LeftStr(Code, Length(Code) - 2) + ')'; // remove last ', '
  ExecuteCode(Code);
end;

procedure TRConsole.AssignStringVector(AVariable: Ansistring; AVector: PStrVector; ASize: LongInt);
var
  i:     LongInt;
  Code:  Ansistring;
  Dummy: TMqlStr;
begin
  if not Running then
    exit;

  try
    Dummy := AVector^[ASize - 1];
  except
    Dummy := Dummy; // suppress compiler note
    Msg(0, 'AssignStringVector', rsErrArraySize);
    exit;
  end;

  Code := AVariable + ' <- c(';
  for i := 0 to ASize - 1 do
  begin
    Code := Code + '"' + WideStringToString(AVector^[i].Ptr, CP_ACP) + '", ';
    if length(Code) > 3000 then
    begin // it does not like too long lines
      Code := LeftStr(Code, Length(Code) - 2) + ')'; // remove last ', '
      ExecuteCode(Code);
      Code := AVariable + ' <- c(' + AVariable + ', ';
    end;
  end;
  Code := LeftStr(Code, Length(Code) - 2) + ')'; // remove last ', '
  ExecuteCode(Code);
end;

procedure TRConsole.AssignMatrix(AVariable: Ansistring; AMatrix: PVector; ARows: LongInt; ACols: LongInt);
var
  F:     TFileStream;
  FN:    Ansistring;
  Dummy: Double;
begin
  if not Running then
    exit;

  try
    // try to read the last element to see whether the size is correct
    Dummy := AMatrix^[ARows * ACols - 1];
  except
    // access violation
    Msg(0, 'AssignMatrix', rsErrArraySize);
    Dummy := Dummy; // suppress the compiler hint about unused variable
    exit;
  end;

  F  := nil;
  // we are usually dealing with very big matrices that contain thousands
  // of vectors of data. The fastest way to transfer them is through
  // writing the entire memory block as it is to a raw binary file and let
  // R read it with readBin() to avoid the slow formatting and parsing.
  FN := GetTempFileName(GetTempDir, 'TRConsole-matrix-' + AVariable + '-');
  FN := StringsReplace(FN, ['\'], ['/'], [rfReplaceAll]);
  try
    Msg(2, 'AssignMatrix', rsWritingData);
    F := TFileStream.Create(FN, fmCreate);
    F.WriteBuffer(AMatrix^, ACols * ARows * 8); // Double is 8 byte
  except
    Msg(0, 'AssignMatrix', rsErrWriteTemp);
    if F <> nil then
    begin
      F.Free;
      DeleteFile(FN);
    end;
    exit;
  end;

  F.Free; // close and force flush
  ExecuteCode(Format(
    '%s <- matrix(readBin("%s", double(), %d), nrow=%d, ncol=%d, byrow=TRUE)',
    [AVariable, FN, ARows * ACols, ARows, ACols]
    ));
  DeleteFile(FN);
end;

procedure TRConsole.AppendMatrixRow(AVariable: Ansistring; AVector: PVector; ASize: LongInt);
const
  TmpVecName = 'trconsole.temp.vector';
begin
  AssignVector(TmpVecName, AVector, ASize);
  ExecuteCode(Format(
    '%s <- rbind(%s,%s); rm(%s)',
    [AVariable, AVariable, TmpVecName, TmpVecName]
    ));
end;

function TRConsole.Exists(AVariable: Ansistring): Boolean;
begin
  Result := GetBoolean(Format('exists("%s")', [AVariable]));
end;

function TRConsole.GetBoolean(ACode: Ansistring): Boolean;
var
  Line: Ansistring;
begin
  if not Running then
    exit(False);
  Line := ExecuteCode('as.logical(' + ACode + ')[1]');
  Line := RightStr(Line, Length(Line) - Pos(']', Line) - 1);
  if Line = 'NA' then
  begin
    Msg(1, 'GetBoolean', rsWarnNA);
    exit(False);
  end;
  if Line = 'TRUE' then
    Result := True
  else
    Result := False;
end;

function TRconsole.GetInteger(ACode: Ansistring): LongInt;
var
  Line: Ansistring;
begin
  if not Running then
    exit(0);
  Line := ExecuteCode('as.integer(' + ACode + ')[1]');
  Line := RightStr(Line, Length(Line) - Pos(']', Line) - 1);
  if Line = 'NA' then
  begin
    Msg(1, 'GetInteger', rsWarnNA);
    exit(0);
  end;
  try
    Result := StrToInt(Line);
  except
    Msg(0, 'GetInteger', rsErrCouldNotConvertToInt, [Line]);
    Result := 0;
  end;
end;

function TRconsole.GetDouble(ACode: Ansistring): Double;
var
  Line: Ansistring;
begin
  if not Running then
    exit(0);
  Line := ExecuteCode('as.double(' + ACode + ')[1]');
  Line := RightStr(Line, Length(Line) - Pos(']', Line) - 1);
  if Line = 'NA' then
  begin
    Msg(1, 'GetDouble', rsWarnNA);
    exit(0);
  end;
  Result := ConvertDouble(Line);
end;

function TRConsole.GetVector(ACode: Ansistring; AVector: PVector; ASize: LongInt): LongInt;
var
  Line:      Ansistring;
  i:         Integer;
  Idx, Pos1, Pos2, Len: Integer;
  ArrayLast: Integer;
begin
  if not Running then
    exit(0);
  ArrayLast := ASize - 1;
  Line      := ExecuteCode('as.vector(' + ACode + ')');
  if Line = 'NULL' then
  begin
    Msg(1, 'GetVector', rsWarnNull);
    exit(0);
  end;

  Line := RightStr(Line, Length(Line) - Pos(']', Line) - 1);
  Len  := Length(Line);

  // replace all line endings with space
  for i := 1 to Len do
  begin
    if Line[i] = #13 then
      Line[i] := ' '
    else if Line[i] = #10 then
      Line[i] := ' ';
  end;

  Idx  := 0; // array index
  Pos1 := 1; // string position
  repeat
    // find next non-whitespace
    while (Pos1 < Len) and (Line[Pos1] = ' ') do
      Pos1 += 1;

    // new line header "[...] "
    if Line[Pos1] = '[' then
    begin
      while (Pos1 < Len) and (Line[Pos1] <> ' ') do
        Pos1 += 1;
      while (Pos1 < Len) and (Line[Pos1] = ' ') do
        Pos1 += 1;
    end;

    // Pos1 is now at the beginning of the number, find next withespace after it
    Pos2 := Pos1;
    while (Pos2 <= Len) and (Line[Pos2] <> ' ') do
      Pos2 += 1;

    if Idx <= ArrayLast then
      AVector^[Idx] := ConvertDouble(MidStr(Line, Pos1, Pos2 - Pos1));

    Pos1 := Pos2;
    Idx  += 1;
  until (Pos2 > Len);

  if (Idx > ASize) then
  begin
    Msg(1, 'GetVector', rsWarnArrayTooSmall, [ASize, Idx]);
    Result := ASize;
  end else
  if (Idx < ASize) then
  begin
    Msg(1, 'GetVector', rsNoteArrayBiggerThanNeeded, [ASize, Idx]);
    Result := Idx;
  end else
    Result := Idx;
end;


{TAsyncExecute}

constructor TAsyncExecute.Create(AConsole: TRConsole; ACode: Ansistring);
begin
  FConsole := AConsole;
  FCode    := ACode;
  inherited Create(False);
end;

procedure TAsyncExecute.Execute;
var
  ExecOut: Ansistring;
begin
  FreeOnTerminate := True;
  if FConsole.Running then
  begin
    FConsole.FLastCode := FCode;
    FConsole.Msg(2, 'ExecuteCodeAsync', 'in  >>>  ' + FCode);
    FCode := FCode + LineEnding;
    FConsole.Input.Write(FCode[1], Length(FCode));
    ExecOut := Trim(FConsole.GetOutput);
    ExecOut := RightStr(ExecOut, Length(ExecOut) - Length(FCode)); // remove echo
    FConsole.Msg(2, 'ExecuteCodeAsync', 'out <<<  ' + ExecOut);
  end;
  FConsole.SetNotBusy;
end;

{TPlotEventLoop}

constructor TPlotEventLoop.Create(AConsole: TRConsole);
begin
  FConsole := AConsole;
  inherited Create(False);
end;

procedure TPlotEventLoop.Execute;
var
  i: Integer;
begin
  FreeOnTerminate := True;
  while FConsole.Running and not FConsole.FStopping do
  begin
    if not FConsole.Busy then
    begin
      FConsole.WaitNotBusy;
      if not FConsole.Running then
        break;
      FConsole.Input.Write(LineEnding, Length(LineEnding));
      FConsole.GetOutput;
      FConsole.SetNotBusy;
    end;
    for i := 1 to 20 do
    begin
      Sleep(10);
      if FConsole.FStopping then
        break;
    end;
  end;
  FConsole.Msg(-1, 'TPlotEventLoop', 'terminating');
end;

end.

