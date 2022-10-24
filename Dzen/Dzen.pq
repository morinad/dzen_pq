// This file contains your Data Connector logic
section Dzen;

[DataSource.Kind="Dzen", Publish="Dzen.Publish"]
shared Dzen.Data = Value.ReplaceType(Dzen.Func, FuncType);


FuncType = type function (
    publisher as (type text meta 
    [
        Documentation.FieldCaption = "ID паблишера:",
        Documentation.SampleValues = {"6cefh3f50b4f2c8az"}
    ]),
     
        
    reportType as (type text meta 
    [
        Documentation.FieldCaption = "Тип отчёта:",
        Documentation.AllowedValues = { "daily-stats", "publications-daily-stats", "previews-daily-stats"}
    ]),

    date1 as (type text meta 
    [
        Documentation.FieldCaption = "Дата начала:",
        Documentation.SampleValues = {"2022-02-28"}
    ]),

    date2 as (type text meta 
    [
        Documentation.FieldCaption = "Дата окончания:",
        Documentation.SampleValues = {"yesterday"}
    ]),
    
    delay as (type text meta 
    [
        Documentation.FieldCaption = "Задержка между запросами:",
        Documentation.SampleValues = {"5"}
    ])

    )
    as table meta [
        Documentation.Name = "Забираем данные из Яндекс.Дзен (или просто Дзен)",
        Documentation.LongDescription =  "",
        Documentation.Examples = {
        [
           Description = "Ссылка или пример запроса",
            Code = "dzen(""6cefh3f50b4f2c8az"", ""daily-stats"", ""2022-02-28"", ""yesterday"", ""5"")",
            Result = "Таблица с результатами" 
        ]
        }
    ];



Dzen.Func =  (publisher as text,  reportType as text, date1 as text, date2 as text, delay as text)=>

let
realUrl = 
    if reportType = "daily-stats" then "api/promo/v1/reports/campaigns-daily-stats" else
    if reportType = "publications-daily-stats" then "api/promo/v1/reports/campaigns-publications-daily-stats" else
    if reportType = "previews-daily-stats" then "api/promo/v1/reports/campaigns-previews-daily-stats" else
    null,
token = Extension.CurrentCredential()[Key],
pageList = List.Generate(()=> "", each _ <> null, each try getCamp(publisher,token, _, "pageLastId") otherwise null ),
#"Преобразовано в таблицу" = Table.FromList(pageList, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
#"Переименованные столбцы" = Table.RenameColumns(#"Преобразовано в таблицу",{{"Column1", "pageToken"}}),
#"Измененный тип" = Table.TransformColumnTypes(#"Переименованные столбцы",{{"pageToken", type text}}),
#"Добавлен пользовательский объект" = Table.AddColumn(#"Измененный тип", "Пользовательский", each getCamp(publisher, token, [pageToken], "campaigns")),
#"Развернутый элемент Пользовательский" = Table.ExpandListColumn(#"Добавлен пользовательский объект", "Пользовательский"),
#"Развернутый элемент Пользовательский1" = Table.ExpandRecordColumn(#"Развернутый элемент Пользовательский", "Пользовательский", {"id", "title", "type", "strategy", "targeting", "start", "publications"}, {"campaign_id", "campaign_title", "campaign_type", "campaign_strategy", "campaign_targeting", "campaign_start", "campaign_publications"}),
#"Удаленные столбцы" = Table.RemoveColumns(#"Развернутый элемент Пользовательский1",{"pageToken"}),
campaigns = Table.TransformColumnTypes(#"Удаленные столбцы",{{"campaign_id", type text}, {"campaign_title", type text}, {"campaign_type", type text}, {"campaign_start", type datetime}}),

campaign_id = campaigns[campaign_id],
campList = Text.Combine(List.Accumulate(campaign_id, {}, (st,cr)=> st & {"""" & cr & """"}), ","),

reportPost = postReport(publisher, token, realUrl, campList, dateFunc(date1), dateFunc(date2)) ,

status= (delay)=> Function.InvokeAfter(()=>Value.Metadata(getReport(reportPost, token,"web"))[Response.Status], #duration(0,0,0,delay)),

getstatus =  List.Generate(()=>202, each Number.From(_)=202, each status(Number.From(delay)) ),

final = getReport(reportPost, token,Text.From(List.Count(getstatus))),
#"Дублированный столбец" = Table.DuplicateColumn(final, "Column1", "data"),
#"Развернутый элемент data" = Table.ExpandRecordColumn(#"Дублированный столбец", "Column1", {"campaignId"}, {"campaignId"}),
#"Измененный тип1" = Table.TransformColumnTypes(#"Развернутый элемент data",{{"campaignId", type text}}),
Пользовательский1 = Table.Join( #"Измененный тип1", {"campaignId"}, campaigns,{"campaign_id"}, JoinKind.LeftOuter),
#"Удаленные столбцы1" = Table.RemoveColumns(Пользовательский1,{"campaignId"})

in #"Удаленные столбцы1";


getCamp= (publisher, token, page, field) =>
Record.Field(Json.Document(Web.Contents("https://promopages.yandex.ru/", 
[ RelativePath = "api/promo/v1/campaigns", Headers = [#"Authorization" = "Bearer "&token, #"Content-Type" = "application/json"], 
ManualStatusHandling = {404, 400}, 
Query =[#"publisherId" = publisher, #"pageLimit" = "200", #"pageLastId" = page]])), field);

dateFunc=(dat)=>
if dat = "yesterday" then Date.ToText(Date.AddDays(Date.From(DateTime.LocalNow()) , -1),"yyyy-MM-dd") 
else if dat = "today" then Date.ToText(Date.From(DateTime.LocalNow()),"yyyy-MM-dd")
else if (try Number.From(Text.BeforeDelimiter(dat,"daysAgo")) otherwise 0) >0 then Date.ToText(Date.AddDays(Date.From(DateTime.LocalNow()),-1*Number.From(Text.BeforeDelimiter(dat,"daysAgo"))),"yyyy-MM-dd") 
else Date.ToText(Date.From(dat),"yyyy-MM-dd");


getReport = (reportId, token, out)=>
let
web = Web.Contents("https://promopages.yandex.ru/", [IsRetry = true, RelativePath ="api/promo/v1/reports/"&reportId, Headers = [#"Authorization" = "Bearer "&token, #"Content-Type" = "application/json"], ManualStatusHandling = {404, 400}, Query = [#"format" = "json"]]),
tbl = Table.FromList(Json.Document(web)[statistics], Splitter.SplitByNothing(), null, null, ExtraValues.Error)
in if out = "web" then web else tbl;


postReport = (publisher, token, url, campaigns, date1, date2)=>
Json.Document(Web.Contents("https://promopages.yandex.ru/", 
[ RelativePath = url, Headers = [#"Authorization" = "Bearer "&token, #"Content-Type" = "application/json"], ManualStatusHandling = {404, 400}, Content = Json.FromValue( Json.Document(Text.ToBinary("{
  ""publisherId"": """ & publisher &""",
  ""campaignIds"": ["& campaigns &"],
  ""mskDateFrom"": """ & date1 &""",
  ""mskDateTo"": """ & date2 &"""
  }")))]))[reportId];


Dzen = [
    TestConnection = (dataSourcePath) => 
        { "Dzen.Data", 
        Json.Document(dataSourcePath)[publisher], 
        Json.Document(dataSourcePath)[reportType],
        Json.Document(dataSourcePath)[date1], 
        Json.Document(dataSourcePath)[date2], 
        Json.Document(dataSourcePath)[delay]
        },
    
    Authentication = [
        
         Key = []
   
    ],
    Label = "Dzen Connection"
];


Dzen.Publish = [
    Beta = false,
    Category = "Other",
    ButtonText = { "Dzen Connector", "Dzen Help" },
    LearnMoreUrl = "",
    SourceImage = Dzen.Icons,
    SourceTypeImage = Dzen.Icons
];


Dzen.Icons = [
    Icon16 = { Extension.Contents("Dzen16.png"), Extension.Contents("Dzen20.png"), Extension.Contents("Dzen24.png"), Extension.Contents("Dzen32.png") },
    Icon32 = { Extension.Contents("Dzen32.png"), Extension.Contents("Dzen40.png"), Extension.Contents("Dzen48.png"), Extension.Contents("Dzen64.png") }
];