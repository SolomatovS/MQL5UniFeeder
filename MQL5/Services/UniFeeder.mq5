#property service
#property copyright "Copyright 2019, Solomatov Sergei (solomatovs@gmail.com)"
#property version   "1.00"

#include <UniFeederSocket.mqh>
#include <Generic\ArrayList.mqh>
#include <JAson.mqh>

input string Host    =  "0.0.0.0";
input ushort Port    =  5001;
input string User    = "quotes";
input string Passord = "quotes";
input int    PeriodInactiveClient = 10;      // Second: Период проверки неактивных подключений (закрытие)
input int    PeriodAcceptClient = 0;         // Second: Период проверки новых подключений (открытие)
input int    PeriodReceiveMessage = 0;       // Second: Период проверки новых сообщений от клиентов (обработки)
input int    PeriodUnAuthClient = 180;       // Second: Период проверки не авторизованных клиентов (закрытие)
input int    PeriodPing = 5;                 // Second: Период отправки Ping клиенту для проверки состояния связи
input int    PeriodStartServer = 1;          // Second: Периодичность попыток стартовать UniFeeder после ошибки запуска
input int    PeriodUpdateMs = 10;            // MilliSecond: Период засыпания программы после выполнения одного рабочего цикла
input string JsonFile = "UniFeeder.json";    // Path to Mapping file: File->Open Data Folder->MQL5->Files
input int    FileEncodingType = FILE_ANSI;   // ANSI=32 or UNICODE=64
input bool   Profiling = false;



void OnStart()
{
   UniFeederAuth auth; auth.m_login = User; auth.m_password = Passord;
   CArrayList<UniFeederSymbol*> symbols;
   UniFeederJsonMapper mapper; mapper.Mapping(JsonFile, symbols);
   
   UniFeederServer *server = new UniFeederServer(Host, Port, auth);
   server.SetPeriodInactiveClient(PeriodInactiveClient);
   server.SetPeriodAcceptClient(PeriodAcceptClient);
   server.SetPeriodReceiveMessage(PeriodReceiveMessage);
   server.SetPeriodUnAuthClient(PeriodUnAuthClient);
   server.SetPeriodPing(PeriodPing);
   
   int ticks = 0;
   ulong last_profiling = GetMicrosecondCount();
   
   while(!IsStopped()) {
      if(!server.IsStarted()) {
         server.StartSocket();
         Sleep(PeriodStartServer * 1000);
         continue;
      }
      
      last_profiling = GetMicrosecondCount();
      // Обработка подключений клиентов, удаление старых, ответы на сообщения
      server.Process();
      SetProfiling(Profiling, StringFormat("%f seconds: accept new client; delete inactive client; delete not authorize client; receive/send message", GetSeconds(last_profiling)));
      
      last_profiling = GetMicrosecondCount();
      ticks = 0;
      // отправка котировок авторизованым клиентам
      for (int i = 0; i < symbols.Count(); i++)
      {
         UniFeederSymbol *s;
         if (symbols.TryGetValue(i, s))
         {
            MqlTick tick;
            if(SymbolInfoTick(s.Source(), tick))
            {
               s.SetQuote(tick);
               if (s.IsChanged())
               {
                  string unifeeder_quote = s.UniFeederString();
                  server.SendAuthorizedClients(unifeeder_quote);
                  ticks++;
               }
            }
         }
      }
      SetProfiling(Profiling, StringFormat("%f seconds: sent %i quotes of %i symbols", GetSeconds(last_profiling), ticks, symbols.Count()));
      
      Sleep(PeriodUpdateMs);
   }
   
   for (int i = 0; i < symbols.Count(); i++)
   {
      UniFeederSymbol *s;
      if (symbols.TryGetValue(i, s))
      {
         delete s;
      }
   }
   
   delete server;
}

class UniFeederSymbol
{
private:
   string m_name;
   string m_source;
   int    m_digits;
   int    m_bid_markup;
   int    m_ask_markup;
   double m_percent;
   int m_max;
   int m_min;
   int m_fix;
   double m_last_bid;
   double m_last_ask;
   MqlTick m_last_tick;
   bool   m_change;
   
public:
   void UniFeederSymbol(string name, string source, int digits)
   {
      Init(name, source, digits, 0, 0, 0, -1, -1, -1);
   }
   
   void UniFeederSymbol(string name, string source, int digits, int bid_markup, int ask_markup, double percent, int max, int min, int fix)
   {
      Init(name, source, digits, bid_markup, ask_markup, percent, max, min, fix);
   }

private:
   void Init(string name, string source, int digits, int bid_markup, int ask_markup, double percent, int max, int min, int fix)
   {
      this.m_name = name;
      this.m_source = source;
      this.m_digits = digits;
      this.m_bid_markup = bid_markup;
      this.m_ask_markup = ask_markup;
      this.m_percent = percent;
      this.m_max = max;
      this.m_min = min;
      this.m_fix = fix;
      this.m_change = false;
   }
   
public:
   string Source()
   {
      return m_source;
   }
   
   void SetQuote(MqlTick &tick)
   {
      // Модифицирую котировки только если новый тик не равен старому по bid или ask
      if (m_last_tick.ask != tick.ask || m_last_tick.bid != tick.bid)
      {
         double last_bid = tick.bid;
         double last_ask = tick.ask;
         double point = MathPow(10, -m_digits);
         double contract = MathPow(10, m_digits);
         
         if (m_bid_markup != 0)
         {
            last_bid = last_bid + point * m_bid_markup;
         }
         
         if (m_ask_markup != 0)
         {
            last_ask = last_ask + point * m_ask_markup;
         }
         
         if (m_percent != 0)
         {
            double point_modify = (last_ask - last_bid) * m_percent / 100 / 2;
            last_bid = last_bid - point_modify;
            last_ask = last_ask + point_modify;
         }
         
         if (m_min != -1)
         {
            double spread = (last_ask - last_bid) * contract;
            if (spread < m_min)
            {
               double last_mid = (last_bid + last_ask) / 2;
               last_bid = last_mid - (m_min * point / 2);
               last_ask = last_mid + (m_min * point / 2);
            }
         }
         
         if (m_max != -1)
         {
            double spread = (last_ask - last_bid) * contract;
            if (spread > m_max)
            {
               double last_mid = (last_bid + last_ask) / 2;
               last_bid = last_mid - (m_max * point / 2);
               last_ask = last_mid + (m_max * point / 2);
            }
         }
         
         if (m_fix != -1)
         {
            double last_mid = (last_bid + last_ask) / 2;
            last_bid = last_mid - (m_fix * point / 2);
            last_ask = last_mid + (m_fix * point / 2);
         }
         
         last_bid = NormalizeDouble(last_bid, m_digits);
         last_ask = NormalizeDouble(last_ask, m_digits);
         
         if (last_ask != m_last_ask || last_bid != m_last_bid)
         {
            m_last_bid = last_bid;
            m_last_ask = last_ask;
            m_change = true;
         }
      }
      m_last_tick = tick;
   }
   
   bool IsChanged()
   {
      if (m_change)
      {
         m_change = false;
         return true;
      }
      return false;
   }
   
   string UniFeederString()
   {
      return m_name + " " + DoubleToString(m_last_bid, m_digits) + " " + DoubleToString(m_last_ask, m_digits) + "\n\r";
   }
   
   string ConfigurationPrint()
   {
      return StringFormat("Symbol: %s,\tSource: %s,\tDigits: %d,\tBidMarkup: %d,\tAskMarkup: %d,\tPercent: %f,\tMin: %d,\tMax: %d,\tFix: %d", m_name, m_source, m_digits, m_bid_markup, m_ask_markup, m_percent, m_min, m_max, m_fix);
   }
};

class UniFeederJsonMapper
{
private:
   CJAVal js;
public:
   UniFeederJsonMapper()
   {
   }
   
private:
   bool File(string file_path, string &text)
   {
      ResetLastError(); 
      int file_handle=FileOpen(file_path, FILE_READ|FILE_TXT|FileEncodingType); 
      if(file_handle != INVALID_HANDLE) 
      {
         PrintFormat("Файл %s открыт для чтения", file_path); 
         PrintFormat("Путь к файлу: %s\\MQL5\\Files\\", TerminalInfoString(TERMINAL_DATA_PATH)); 
         //--- прочитаем данные из файла 
         while(!FileIsEnding(file_handle)) 
         { 
            text += FileReadString(file_handle); 
         } 
         //--- закроем файл 
         FileClose(file_handle); 
         PrintFormat("Данные прочитаны, файл %s закрыт", file_path);
         return true;
      } 
      else
      {
         PrintFormat("Не удалось открыть файл %s\\MQL5\\Files\\%s, Код ошибки = %d", TerminalInfoString(TERMINAL_DATA_PATH), file_path, GetLastError());
         return false;
      }
   }
   
public:
   void Mapping(string file_path, CArrayList<UniFeederSymbol*> &mapping)
   {
      string json;
      if (File(file_path, json))
      {
         json = RemoveSpace(json);
         if (js.Deserialize(json))
         {
            printf("json файл валидный, беру данные из него");
            int i = 0; string name = "";
            do {
               CJAVal s = js["Translates"][i];
               name = s["Symbol"].ToStr();
               if (name != "")
               {
                  string source = s["Source"].ToStr();
                  int digits = (int)s["Digits"].ToInt(); digits = digits == 0 ? (int)SymbolInfoInteger(source, SYMBOL_DIGITS) : digits;
                  double percent = s["Percent"].ToDbl();
                  int bid_markup = (int)s["BidMarkup"].ToInt();
                  int ask_markup = (int)s["AskMarkup"].ToInt();
                  
                  int min = -1;
                  if (s.HasKey("Min"))
                     min = (int)s["Min"].ToInt();
                  
                  int max = -1;
                  if (s.HasKey("Max"))
                     max = (int)s["Max"].ToInt();
                  
                  int fix = -1;
                  if (s.HasKey("Fix"))
                     fix = (int)s["Fix"].ToInt();
                  
                  UniFeederSymbol *sym = new UniFeederSymbol(name, source, digits, bid_markup, ask_markup, percent, max, min, fix);
                  mapping.Add(sym);
                  printf("add symbol: %s", sym.ConfigurationPrint());
                  i++;
               }
            } while(name != "");
         }
         else
            printf("json файл невалидный");
      }
      if (mapping.Count() == 0)
      {
         printf("Настройки маппинга не обнаружены. Делаю маппинг всех символов из терминала");
         int symbols = SymbolsTotal(true);
         for (int i = 0; i < symbols; i++)
         {
            string symbol = SymbolName(i, true);
            UniFeederSymbol *sym = new UniFeederSymbol(symbol, symbol, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
            mapping.Add(sym);
            printf("add symbol: %s", sym.ConfigurationPrint());
         }
      }
   }
   
   string RemoveSpace(string text)
   {
      string replacemen="";
      string find=" ";
      StringReplace(text, find, replacemen);
      
      find = "\r";
      StringReplace(text, find, replacemen);
      
      find = "\n";
      StringReplace(text, find, replacemen);
      
      return text;
   }
};

void SetProfiling(bool need_profoling, string text)
{
   if (need_profoling)
      printf("profiling: %s", text);
}

double GetSeconds(ulong last)
{
   return NormalizeDouble((GetMicrosecondCount() - last), 8) / 1000000;
}