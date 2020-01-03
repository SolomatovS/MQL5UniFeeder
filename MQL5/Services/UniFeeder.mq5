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
input int    PeriodInactiveClient = 10;
input int    PeriodAcceptClient = 0;
input int    PeriodReceiveMessage = 0;
input int    CheckPeriodStartServer = 1;
input int    CheckPeriodUpdateMs = 10;       
input string JsonFile = "UniFeeder.json";    // Folder: File->Open Data Folder->MQL5->Files
input int    FileEncodingType = FILE_ANSI;   // ANSI=32 or UNICODE=64

void OnStart()
{
   UniFeederAuth auth; auth.m_login = User; auth.m_password = Passord;
   CArrayList<UniFeederSymbol*> symbols;
   UniFeederJsonMapper mapper; mapper.Mapping(JsonFile, symbols);
   
   UniFeederServer *server = new UniFeederServer(Host, Port, auth);
   server.SetPeriodInactiveClient(PeriodInactiveClient);
   server.SetPeriodAcceptClient(PeriodAcceptClient);
   server.SetPeriodReceiveMessage(PeriodReceiveMessage);
   
   while(!IsStopped()) {
      if(!server.IsStarted()) {
         server.StartSocket();
         Sleep(CheckPeriodStartServer * 1000);
         continue;
      }

      // Обработка подключений клиентов, удаление старых, ответы на сообщения
      server.Process();
      
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
               }
            }
         }
      }
      
      Sleep(CheckPeriodUpdateMs);
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
   double m_percent;
   double m_max;
   double m_min;
   double m_last_bid;
   double m_last_ask;
   MqlTick m_last_tick;
   bool   m_change;
   
public:
   void UniFeederSymbol(string name, string source, int digits, double percent, double max, double min)
   {
      this.m_name = name;
      this.m_source = source;
      this.m_digits = digits;
      this.m_percent = percent;
      this.m_max = max;
      this.m_min = min;
      this.m_change = false;
   }
   
   string Source()
   {
      return m_source;
   }
   
   void SetQuote(MqlTick &tick)
   {
      double last_bid = tick.bid;
      double last_ask = tick.ask;
      if (m_percent != 0)
      {
         double point_modify = (last_ask - last_bid) * m_percent / 100 / 2;
         last_bid = last_bid - point_modify;
         last_ask = last_ask + point_modify;
      }
      
      if (m_min != -1)
      {
         double spread = (last_ask - last_bid);
         if (spread < m_min)
         {
            double last_mid = (last_bid + last_ask) / 2;
            last_bid = last_mid - (m_min / 2);
            last_ask = last_mid + (m_min / 2);
         }
      }
      
      if (m_max != -1)
      {
         double spread = (last_ask - last_bid);
         if (spread > m_max)
         {
            double last_mid = (last_bid + last_ask) / 2;
            last_bid = last_mid - (m_max / 2);
            last_ask = last_mid + (m_max / 2);
         }
      }
      
      last_bid = NormalizeDouble(last_bid, m_digits);
      last_ask = NormalizeDouble(last_ask, m_digits);
      
      if (last_ask != m_last_ask || last_bid != m_last_bid)
      {
         m_last_bid = last_bid;
         m_last_ask = last_ask;
         m_change = true;
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
      return StringFormat("name: %s, source: %s, digits: %d, percent spread: %f, min spread: %f, max spread: %f", m_name, m_source, m_digits, m_percent, m_min, m_max);
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
               CJAVal s = js["mapping"][i];
               name = s["name"].ToStr();
               if (name != "")
               {
                  string source = s["source"].ToStr();
                  int digits = (int)s["digits"].ToInt(); digits = digits == 0 ? (int)SymbolInfoInteger(source, SYMBOL_DIGITS) : digits;
                  double percent = s["percent"].ToDbl();
                  double min = -1;
                  if (s.HasKey("min"))
                     min = s["min"].ToDbl();
                  
                  double max = -1;
                  if (s.HasKey("max"))
                     max = s["max"].ToDbl();
                  
                  UniFeederSymbol *sym = new UniFeederSymbol(name, source, digits, percent, max, min);
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
            UniFeederSymbol *sym = new UniFeederSymbol(symbol, symbol, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS), 0, 0, 0);
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
