#include <SocketLib.mqh>
#include <Generic\ArrayList.mqh>
#include <Object.mqh>

string ToUniFeederString(uchar &data[], int start_pos = 0, int count = WHOLE_ARRAY)
{
   return CharArrayToString(data, start_pos, count, CP_UTF8);
}

void ToUniFeederByteArray(string text, uchar &data[], int start_pos = 0, int count = WHOLE_ARRAY)
{
   StringToCharArray(text, data, 0, count, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);
}

class SocketClient : CObject
{
private:
   SOCKET64 m_socket;
   
public:
   SocketClient(SOCKET64 &socket)
   {
      m_socket = socket;
      printf("socket %d accepted", m_socket);
   }
  ~SocketClient(void)
   {
      CloseSocket();
   }
   bool IsStarted() {
      return m_socket != INVALID_SOCKET64;
   }
   
protected:
   void CloseSocket()
   {
      if(m_socket == INVALID_SOCKET64)
         return;
      
      printf("close socket %d", m_socket);
      if(shutdown(m_socket, SD_BOTH) == SOCKET_ERROR)
      {
         Print("shutdown failed error: " + WSAErrorDescript(WSAGetLastError()));
      }
      
      closesocket(m_socket);
      m_socket = INVALID_SOCKET64;
   }
   
   bool SendFromSocket(uchar &data[])
   {
      if(m_socket == INVALID_SOCKET64) return false;
      
      int len = ArraySize(data);
      int res = send(m_socket, data, len, 0);
      if (res == SOCKET_ERROR) {
         int err = WSAGetLastError();
         if(err != WSAEWOULDBLOCK) {
            Print("send failed error: " + string(err) + " "+WSAErrorDescript(err));
            CloseSocket();
            return false;
         }
      }
      
      return true;
   }
   
   bool ReceiveFromSocket(uchar &rdata[]) {
      if(m_socket == INVALID_SOCKET64) return false;
      
      char rbuf[512]; int rlen=512; int r=0,res=0;
      do {
         res = recv(m_socket, rbuf, rlen, 0);
         if(res == SOCKET_ERROR) {
            int err = WSAGetLastError();
            if(err != WSAEWOULDBLOCK) {
               Print("receive failed error: "+string(err)+" "+WSAErrorDescript(err));
               CloseSocket();
               return false;
            }
            break;
         }
         if(res == 0 && r == 0) {
            Print("receive. connection closed");
            CloseSocket();
            return false;
         }
         r+=res; ArrayCopy(rdata,rbuf,ArraySize(rdata),0,res);
      }
      while(res>0 && res>=rlen);
      
      return res > 0 ? true : false;
   }

public:
   bool SwitchNonBlockingMode()
   {
      if(m_socket == INVALID_SOCKET64)
         return false;
      
      int non_block = 1;
      int res = ioctlsocket(m_socket, (int)FIONBIO, non_block);
      if(res != NO_ERROR) {
         printf("ioctlsocket failed error: " + string(res));
         return false;
      }
      
      return true;
   }
};

struct UniFeederAuth
{
   string m_login;
   string m_password;
   
public:
   UniFeederAuth()
   {
      m_login = "";
      m_password = "";
   }
   
   bool IsFilled()
   {
      return !(m_login == "" || m_password == "");
   }
   
   bool Equals(UniFeederAuth& auth)
   {
      return m_login == auth.m_login && m_password == auth.m_password;
   }
};

class UniFeeder : public SocketClient
{
private:
   string         m_lastBuffer;
   UniFeederAuth  m_auth;
   UniFeederAuth  m_credintails;

public:
   UniFeeder(SOCKET64 &socket, UniFeederAuth &credintails) : SocketClient(socket)
   {
      this.m_credintails = credintails;
      this.SwitchNonBlockingMode();
      Init();
   }
   
   void Receive(void)
   {
      uchar data[];
      if(ReceiveFromSocket(data))
      {
         ReceiveByte(data);
      }
   }
   
   void Send(uchar &data[])
   {
      if (IsStarted())
         this.SendFromSocket(data);
   }
   
   bool IsAuthorized()
   {
      return m_credintails.Equals(m_auth);
   }

protected:
   void ReceiveByte(uchar &data[])
   {
      string message = ToUniFeederString(data, 0, WHOLE_ARRAY);
      printf("socket receive %s", message);
      ArrayPrint(data);

      if (!this.IsAuthorized())
      {
         if (!m_auth.IsFilled())
         {
            int length = ArraySize(data);
            int positionDivider = length;
            bool dividerExists = false;
            for(int i = 0; i < length; i++)
            {
               if(IsUniFeederDivider(data[i]))
               {
                  positionDivider = i;
                  dividerExists = true;
                  break;
               }
            }
            
            m_lastBuffer += ToUniFeederString(data, 0, positionDivider);
            
            if (dividerExists)
            {
               uchar replay[];
               switch(FillAuth(m_lastBuffer))
               {
               case 1: /*принял логин*/
                  printf("send password request...");
                  ToUniFeederByteArray("> Password: \r\n", replay, 0, WHOLE_ARRAY);
                  ArrayPrint(replay);
                  this.SendFromSocket(replay);
               break;
               case 2: /*принял пароль*/
                  // не нужно ничего делать
               break;
               
               default: break;
               }
               
               m_lastBuffer = "";
            }
         }
         
         if (m_auth.IsFilled())
         {
            uchar replay[];
            
            if (this.IsAuthorized())
            {
               printf("access granted");
               ToUniFeederByteArray("> Access granted\r\n", replay, 0, WHOLE_ARRAY);
               ArrayPrint(replay);
               this.SendFromSocket(replay);
            }
            else
            {
               printf("access denied");
               ToUniFeederByteArray("> Access denied\r\n", replay, 0, WHOLE_ARRAY);
               ArrayPrint(replay);
               this.SendFromSocket(replay);
               this.CloseSocket();
            }
         }
      }
      else
      {
         // отвечаю на сообщение Ping
         if (message == "> Ping\r\n")
         {
            printf("socket send %s", message);
            ArrayPrint(data);
            this.SendFromSocket(data);
         }
      }
   }

private:
   void Init()
   {
      printf("send login request");
      uchar replay[]; ToUniFeederByteArray("> Universal DDE Connector 9.00\r\n> Copyright 1999 - 2008 MetaQuotes Software Corp.\r\n> Login: \r\n", replay, 0, WHOLE_ARRAY);
      ArrayPrint(replay);
      this.SendFromSocket(replay);
   }
   
   bool IsUniFeederDivider(uchar &data)
   {
      return (data == 13);
   }
   
   int FillAuth(string message)
   {
      if (m_auth.m_login == "")
      {
         m_auth.m_login = message;
         return 1;
      }
      
      if (m_auth.m_password == "")
      {
         m_auth.m_password = message;
         return 2;
      }
      
      return 0;
   }
};

class UniFeederServer : CObject
{
private:
   SOCKET64 m_socket;
   string m_host;
   ushort m_port;
   UniFeederAuth m_creditails;
   CArrayList<UniFeeder*> m_clients;
   datetime m_last_period_inactive_client;
   datetime m_last_period_accept_client;
   datetime m_last_period_receive_message;
   datetime m_last_period_unauth_client;
   datetime m_last_period_ping;
   int m_check_period_inactive_client;
   int m_check_period_accept_client;
   int m_check_period_receive_message;
   int m_check_period_unauth_client;
   int m_check_period_ping;

public:
   UniFeederServer(string host, ushort port, UniFeederAuth &creditails)
   {
      this.m_socket = INVALID_SOCKET64;
      this.m_host = (host == "" ? "0.0.0.0" : host);
      this.m_port = (port == 0 ? 5001 : port);
      this.m_creditails = creditails;
      this.m_last_period_inactive_client = TimeLocal();
      this.m_last_period_accept_client = TimeLocal();
      this.m_last_period_receive_message = TimeLocal();
      this.m_last_period_unauth_client = TimeCurrent();
      this.m_last_period_ping = TimeCurrent();
      this.m_check_period_inactive_client = 1;
      this.m_check_period_accept_client = 1;
      this.m_check_period_receive_message = 1;
      this.m_check_period_unauth_client = 1;
      this.m_check_period_ping = 1;
   }
   
  ~UniFeederServer()
  {
      printf("close clients");
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            delete c;
            m_clients.RemoveAt(i);
         }
      }
      m_clients.TrimExcess();
      
      printf("close socket");
      CloseSocket();
  }
  
private:
   void CloseSocket()
   {
      if(m_socket != INVALID_SOCKET64)
      {
         closesocket(m_socket);
         m_socket = INVALID_SOCKET64;
      }
      
      WSACleanup();
   }
   
public:
   void SetPeriodInactiveClient(int seconds)
   {
      this.m_check_period_inactive_client = seconds;
   }
   void SetPeriodAcceptClient(int seconds)
   {
      this.m_check_period_accept_client = seconds;
   }
   void SetPeriodReceiveMessage(int seconds)
   {
      this.m_check_period_receive_message = seconds;
   }
   void SetPeriodUnAuthClient(int seconds)
   {
      this.m_check_period_unauth_client = seconds;
   }
   void SetPeriodPing(int second)
   {
      this.m_check_period_ping = second;
   }
   
   bool IsStarted()
   {
      return m_socket != INVALID_SOCKET64;
   }
   
   void SendAuthorizedClients(const string &text)
   {
      uchar data[]; ToUniFeederByteArray(text, data, 0, WHOLE_ARRAY);
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            if (c.IsAuthorized())
               c.Send(data);
         }
      }
   }
   
   void Process()
   {
      if(m_socket == INVALID_SOCKET64) return;
      
      // Получаю отправленные сообщения и обрабатываю их
      if (TimeLocal() >= this.m_last_period_receive_message + this.m_check_period_receive_message) {
         ReceiveMessage();
         this.m_last_period_receive_message = TimeLocal();
      }      
      
      // Accept new clients
      if (TimeLocal() >= this.m_last_period_accept_client + this.m_check_period_accept_client) {
         AcceptClients();
         this.m_last_period_accept_client = TimeLocal();
      }
      
      // Проверяю неактивные соединения и удаляю их
      if (TimeLocal() >= this.m_last_period_inactive_client + this.m_check_period_inactive_client) {
         CleanInactiveClients();
         this.m_last_period_inactive_client = TimeLocal();
      }
      
      // Проверяю неавторизованные соединения и убиваю их
      if (TimeLocal() >= this.m_last_period_unauth_client + this.m_check_period_unauth_client) {
         CleanUnAuthClients();
         this.m_last_period_unauth_client = TimeLocal();
      }
      
      // пингую сервер
      if (TimeLocal() >= this.m_last_period_ping + this.m_check_period_ping) {
         Ping();
         this.m_last_period_ping = TimeLocal();
      }
   }

   void StartSocket()
   {
      // инициализируем библиотеку
      char wsaData[]; ArrayResize(wsaData,sizeof(WSAData));
      int res = WSAStartup(MAKEWORD(2,2), wsaData);
      if(res != 0) {
         Print("WSAStartup failed error: " + string(res));
         return;
      }
   
      // создаём сокет
      m_socket = socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
      if(m_socket == INVALID_SOCKET64) {
         Print("create failed error: " + WSAErrorDescript(WSAGetLastError()));
         CloseSocket();
         return;
      }
   
      // биндимся к адресу и порту
      Print("try bind "+m_host+":"+string(m_port));
      
      char ch[]; ToUniFeederByteArray(m_host, ch, 0, WHOLE_ARRAY);
      sockaddr_in addrin;
      addrin.sin_family=AF_INET;
      addrin.sin_addr.u.S_addr=inet_addr(ch);
      addrin.sin_port=htons(m_port);
      ref_sockaddr ref; ref.in=addrin;
      if(bind(m_socket, ref.ref, sizeof(addrin)) == SOCKET_ERROR) {
         int err = WSAGetLastError();
         if(err != WSAEISCONN) {
            Print("connect failed error: " + WSAErrorDescript(err) + ". Cleanup socket");
            CloseSocket();
            return;
         }
      }
   
      // ставим в неблокирующий режим
      int non_block = 1;
      res = ioctlsocket(m_socket,(int)FIONBIO,non_block);
      if(res!=NO_ERROR) {
         Print("ioctlsocket failed error: " + string(res));
         CloseSocket();
         return;
      }
   
      // слушаем порт и акцептируем коннекты клиентов
      if(listen(m_socket,SOMAXCONN)==SOCKET_ERROR) {
         Print("listen failed with error: ", WSAErrorDescript(WSAGetLastError()));
         CloseSocket();
         return;
      }
         
      Print("socket started");
   }


private:
   void ReceiveMessage()
   {
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            c.Receive();
         }
      }
   }
   
   void CleanInactiveClients()
   {
      if(m_socket == INVALID_SOCKET64) return;
      
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            if (!c.IsStarted())
            {
               delete c;
               m_clients.RemoveAt(i);
            }
         }
      }
   }
   
   void CleanUnAuthClients()
   {
      if(m_socket == INVALID_SOCKET64) return;
      
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            if (!c.IsStarted() || !c.IsAuthorized())
            {
               delete c;
               m_clients.RemoveAt(i);
            }
         }
      }
   }
   
   void Ping()
   {
      if(m_socket == INVALID_SOCKET64) return;
      
      string message = "> Ping\r\n"; uchar data[];
      ToUniFeederByteArray(message, data, 0, WHOLE_ARRAY);
      for(int i = 0; i < m_clients.Count(); i++)
      {
         UniFeeder* c;
         if (m_clients.TryGetValue(i, c))
         {
            if (c.IsStarted() && c.IsAuthorized())
            {
               printf("socket sent: %s", message);
               ArrayPrint(data);
               c.Send(data);
            }
         }
      }
   }
   
   void AcceptClients()
   {
      if(m_socket == INVALID_SOCKET64) return;
      
      // добавляем всех ожидающих клиентов
      SOCKET64 socket_client = INVALID_SOCKET64;
      do {
         ref_sockaddr ch; int len = sizeof(ref_sockaddr);
         socket_client = accept(m_socket, ch.ref, len);
         if(socket_client == INVALID_SOCKET64)  {
            int err = WSAGetLastError();
            if(err != WSAEWOULDBLOCK)
               Print("Accept failed with error: ", WSAErrorDescript(err));
            
            return;
         }
         
         // добавляем сокет клиента в массив
         m_clients.Add(new UniFeeder(socket_client, m_creditails));
      }
      while(socket_client != INVALID_SOCKET64);
   }
};
