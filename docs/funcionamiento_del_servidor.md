# Funcionamiento del servidor

El proyecto utiliza sockets TCP para comunicar el cliente con el
servidor. El servidor escucha en el puerto 6666 y crea un proceso
hijo para atender cada conexión.

## Recorrido de una consulta

1. El cliente establece una conexión con el servidor.
2. El proceso padre acepta la conexión mediante accept().
3. El servidor crea una tubería anónima con pipe().
4. Mediante fork(), crea un hijo que atenderá al cliente.
5. Antes de procesar la consulta, el hijo envía la dirección IP
   del cliente al padre a través de la tubería.
6. El padre lee esa dirección y muestra la IP y el PID del hijo.
7. El hijo recibe el código del episodio, busca sus datos y envía
   la respuesta al cliente.
8. El hijo cierra la conexión y termina. El padre continúa
   aceptando conexiones.

## Comunicación por sockets y por tuberías

El socket TCP transporta la consulta y la respuesta entre el
cliente y el hijo que lo atiende.

La tubería comunica al hijo con el padre dentro del servidor.
Se utiliza para informar la dirección IP del cliente. Cada proceso
cierra los extremos y descriptores que no necesita.

## Atención de varios clientes

Cada conexión tiene un proceso hijo independiente. Por ello, un
cliente que tarda en enviar su código no impide que otros hijos
atiendan sus consultas.

El programa establece tiempos de espera para las operaciones de
comunicación con los clientes.

## Formato de la consulta

El cliente envía los seis caracteres del código, por ejemplo
S01E05. TCP transmite un flujo de bytes y una lectura puede recibir
solo una parte del código. Por eso, leer_codigo() repite la lectura
hasta completar los seis caracteres o detectar un cierre o error.

La función escribir_todo() también repite la escritura cuando una
operación no consigue enviar todos los bytes.

## Manejo de señales

- SIGINT se ignora, como exige la orientación.
- SIGCHLD se atiende mediante sigaction(). El manejador utiliza
  waitpid() con WNOHANG para recoger los hijos que han terminado
  y evitar procesos zombis.
- SIGPIPE se ignora para poder manejar como error una escritura
  cuando el receptor ya ha cerrado la conexión.
- SIGTERM permite solicitar la terminación del servidor.

## Biblioteca estática

La biblioteca libmonitor.a contiene la base de datos de episodios
y las funciones auxiliares de lectura, escritura y formato.

El Makefile construye esta biblioteca con ar rcs y la enlaza con
los programas que la utilizan.
