program CrudServer;
{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.ShellAPI,
  SyncObjs,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal;

const
  DATA_FILE = 'data.json';
  STATIC_DIR = 'www';

type
  TCrudServer = class
  private
    FServer: TIdHTTPServer;
    FCS: TCriticalSection;
    function ReadRequestBody(ARequestInfo: TIdHTTPRequestInfo): string;
    function LoadArray: TJSONArray;
    procedure SaveArray(arr: TJSONArray);
    procedure SendFile(AResponseInfo: TIdHTTPResponseInfo; const APath: string);
    procedure HandleRequest(AContext: TIdContext;
      ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
  public
    constructor Create(APort: Integer = 8080);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

  { TCrudServer }

constructor TCrudServer.Create(APort: Integer);
begin
  inherited Create;
  FCS := TCriticalSection.Create;
  FServer := TIdHTTPServer.Create(nil);
  FServer.DefaultPort := APort;
  FServer.OnCommandGet := HandleRequest;
  FServer.OnCommandOther := HandleRequest;
end;

destructor TCrudServer.Destroy;
begin
  if Assigned(FServer) then
  begin
    FServer.Active := False;
    FreeAndNil(FServer);
  end;
  FreeAndNil(FCS);
  inherited;
end;

procedure TCrudServer.Start;
begin
  if Assigned(FServer) then
    FServer.Active := True;
end;

procedure TCrudServer.Stop;
begin
  if Assigned(FServer) then
    FServer.Active := False;

end;

function TCrudServer.ReadRequestBody(ARequestInfo: TIdHTTPRequestInfo): string;
var
  ss: TStringStream;
begin
  Result := '';
  if (ARequestInfo.PostStream = nil) or (ARequestInfo.PostStream.Size = 0) then
    Exit;
  ss := TStringStream.Create('', TEncoding.UTF8);
  try
    ARequestInfo.PostStream.Position := 0;
    ss.CopyFrom(ARequestInfo.PostStream, ARequestInfo.PostStream.Size);
    Result := ss.DataString;
  finally
    ss.Free;
  end;
end;

function TCrudServer.LoadArray: TJSONArray;
var
  sl: TStringList;
  jsonVal: TJSONValue;
begin
  if FileExists(DATA_FILE) then
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(DATA_FILE, TEncoding.UTF8);
      jsonVal := TJSONObject.ParseJSONValue(sl.Text);
      if (jsonVal <> nil) and (jsonVal is TJSONArray) then
        Result := jsonVal as TJSONArray
      else
      begin
        jsonVal.Free;
        Result := TJSONArray.Create;
      end;
    finally
      sl.Free;
    end;
  end
  else
    Result := TJSONArray.Create;
end;

procedure TCrudServer.SaveArray(arr: TJSONArray);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := arr.ToString;
    sl.SaveToFile(DATA_FILE, TEncoding.UTF8);
  finally
    sl.Free;
  end;
end;

procedure TCrudServer.SendFile(AResponseInfo: TIdHTTPResponseInfo;
  const APath: string);
var
  full: string;
  sl: TStringList;
  ext: string;
begin
  full := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) +
    STATIC_DIR) + APath;
  if FileExists(full) then
  begin
    ext := LowerCase(ExtractFileExt(full));
    if ext = '.html' then
      AResponseInfo.ContentType := 'text/html; charset=utf-8'
    else if ext = '.css' then
      AResponseInfo.ContentType := 'text/css; charset=utf-8'
    else if ext = '.js' then
      AResponseInfo.ContentType := 'application/javascript; charset=utf-8'
    else
      AResponseInfo.ContentType := 'application/octet-stream';
    sl := TStringList.Create;
    try
      sl.LoadFromFile(full, TEncoding.UTF8);
      AResponseInfo.ContentText := sl.Text;
    finally
      sl.Free;
    end;
  end
  else
  begin
    AResponseInfo.ResponseNo := 404;
    AResponseInfo.ContentType := 'application/json; charset=utf-8';
    AResponseInfo.ContentText := '{"error":"file not found"}';
  end;
end;

procedure TCrudServer.HandleRequest(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  arr, newArr: TJSONArray;
  bodyStr: string;
  bodyObj, itemObj: TJSONObject;
  i, idInt: Integer;
  idParam: string;
  path: string;
  tmpVal: TJSONValue;
  found: Boolean;
begin
  AResponseInfo.CharSet := 'utf-8';
  try
    path := ARequestInfo.Document;

    // Static files
    if (path = '/') or (SameText(path, '/index.html')) then
    begin
      SendFile(AResponseInfo, 'index.html');
      Exit;
    end;
    if SameText(path, '/styles.css') then
    begin
      SendFile(AResponseInfo, 'styles.css');
      Exit;
    end;

    // API prefix
    if not SameText(Copy(path, 1, 10), '/api/items') then
    begin
      AResponseInfo.ResponseNo := 404;
      AResponseInfo.ContentType := 'application/json; charset=utf-8';
      AResponseInfo.ContentText := '{"error":"not found"}';
      Exit;
    end;

    AResponseInfo.ContentType := 'application/json; charset=utf-8';

    FCS.Enter;
    try
      arr := LoadArray;
      try
        // GET
        if ARequestInfo.CommandType = hcGET then
        begin
          idParam := ARequestInfo.Params.Values['id'];
          if idParam = '' then
            AResponseInfo.ContentText := arr.ToString
          else
          begin
            for i := 0 to arr.Count - 1 do
            begin
              itemObj := arr.Items[i] as TJSONObject;
              if itemObj.GetValue('id').Value = idParam then
              begin
                AResponseInfo.ContentText := itemObj.ToString;
                Exit;
              end;
            end;
            AResponseInfo.ResponseNo := 404;
            AResponseInfo.ContentText := '{"error":"not found"}';
          end;
          Exit;
        end;

        // POST (create)
        if ARequestInfo.CommandType = hcPOST then
        begin
          bodyStr := ReadRequestBody(ARequestInfo);
          bodyObj := nil;
          try
            if bodyStr <> '' then
              bodyObj := TJSONObject.ParseJSONValue(bodyStr) as TJSONObject;
          except
            bodyObj := nil;
          end;
          if bodyObj = nil then
          begin
            AResponseInfo.ResponseNo := 400;
            AResponseInfo.ContentText := '{"error":"invalid json"}';
            Exit;
          end;
          idInt := 1;
          if arr.Count > 0 then
            idInt := (arr.Items[arr.Count - 1] as TJSONObject).GetValue('id')
              .AsType<Integer> + 1;
          bodyObj.AddPair('id', TJSONNumber.Create(idInt));
          arr.AddElement(bodyObj);
          SaveArray(arr);
          AResponseInfo.ResponseNo := 201;
          AResponseInfo.ContentText := bodyObj.ToString;
          Exit;
        end;

        // PUT (update) - reconstruction safe du tableau
        if ARequestInfo.CommandType = hcPUT then
        begin
          idParam := ARequestInfo.Params.Values['id'];
          if idParam = '' then
          begin
            AResponseInfo.ResponseNo := 400;
            AResponseInfo.ContentText := '{"error":"missing id"}';
            Exit;
          end;

          bodyStr := ReadRequestBody(ARequestInfo);
          bodyObj := nil;
          try
            if bodyStr <> '' then
              bodyObj := TJSONObject.ParseJSONValue(bodyStr) as TJSONObject;
          except
            bodyObj := nil;
          end;
          if bodyObj = nil then
          begin
            AResponseInfo.ResponseNo := 400;
            AResponseInfo.ContentText := '{"error":"invalid json"}';
            Exit;
          end;

          newArr := TJSONArray.Create;
          try
            found := False;
            for i := 0 to arr.Count - 1 do
            begin
              itemObj := arr.Items[i] as TJSONObject;
              if itemObj.GetValue('id').Value = idParam then
              begin
                // ensure id preserved
                bodyObj.AddPair('id', TJSONNumber.Create(StrToInt(idParam)));
                newArr.AddElement(bodyObj);
                found := True;
              end
              else
              begin
                tmpVal := TJSONObject.ParseJSONValue(itemObj.ToString);
                if tmpVal <> nil then
                  newArr.AddElement(tmpVal);
              end;
            end;

            if not found then
            begin
              newArr.Free;
              AResponseInfo.ResponseNo := 404;
              AResponseInfo.ContentText := '{"error":"not found"}';
              Exit;
            end;

            // replace arr by newArr
            arr.Free;
            arr := newArr;
            newArr := nil;
            SaveArray(arr);
            AResponseInfo.ContentText := bodyObj.ToString;
            Exit;
          finally
            newArr.Free;
          end;
        end;

        // DELETE (rebuild array without the deleted item)
        if ARequestInfo.CommandType = hcDELETE then
        begin
          idParam := ARequestInfo.Params.Values['id'];
          if idParam = '' then
          begin
            AResponseInfo.ResponseNo := 400;
            AResponseInfo.ContentText := '{"error":"missing id"}';
            Exit;
          end;

          newArr := TJSONArray.Create;
          try
            for i := 0 to arr.Count - 1 do
            begin
              itemObj := arr.Items[i] as TJSONObject;
              if itemObj.GetValue('id').Value <> idParam then
              begin
                tmpVal := TJSONObject.ParseJSONValue(itemObj.ToString);
                if tmpVal <> nil then
                  newArr.AddElement(tmpVal);
              end;
            end;

            if newArr.Count = arr.Count then
            begin
              newArr.Free;
              AResponseInfo.ResponseNo := 404;
              AResponseInfo.ContentText := '{"error":"not found"}';
              Exit;
            end;

            arr.Free;
            arr := newArr;
            newArr := nil;
            SaveArray(arr);
            AResponseInfo.ContentText := '{"status":"deleted"}';
            Exit;
          finally
            newArr.Free;
          end;
        end;

        // method not allowed
        AResponseInfo.ResponseNo := 405;
        AResponseInfo.ContentText := '{"error":"method not allowed"}';
      finally
        arr.Free;
      end;
    finally
      FCS.Leave;
    end;
  except
    on E: Exception do
    begin
      AResponseInfo.ResponseNo := 500;
      AResponseInfo.ContentType := 'application/json; charset=utf-8';
      AResponseInfo.ContentText := '{"error":"server error","msg":"' +
        StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
    end;
  end;
end;

{ Programme principal }

var
  App: TCrudServer;

begin
  try
    App := TCrudServer.Create(8080);
    try
      App.Start;
      Writeln('Serveur démarré sur : http://localhost:8080');
      Writeln('Appuyez sur Entrée pour arrêter.');
      ShellExecute(0, 'open', PChar('http://localhost:8080'), nil, nil,
        SW_SHOWNORMAL);
      Readln;
      App.Stop;
    finally
      App.Free;
    end;
  except
    on E: Exception do
      Writeln('Fatal: ', E.ClassName, ' - ', E.Message);
  end;

end.
