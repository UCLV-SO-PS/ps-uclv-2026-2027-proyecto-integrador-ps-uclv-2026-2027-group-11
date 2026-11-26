# The Sopranos — Consulta de calificaciones por TCP

Proyecto integrador de **Programación de Sistemas**, curso 2026–2027.
Carrera: Ciencias de la Computación, tercer año.

## Integrantes

- Luis Manuel Calero Barroso.
- Liannah Maria Perez Perez.
- Tercer integrante: pendiente de confirmar antes de la entrega.

El equipo trabaja de forma conjunta en el diseño, la implementación, la revisión
y las pruebas. Las sesiones se realizan utilizando la computadora de Luis
Manuel, ya que no todos los integrantes disponen de un equipo propio. Los
commits se registran desde su cuenta; el trabajo se organiza de manera
colaborativa.

## Qué hace el programa

El cliente envía el código de un episodio de *A Knight of the Seven Kingdoms*
y el servidor responde con su título, puntuación IMDb y número de votos.
Los datos son los proporcionados en la orientación del proyecto: no se consulta
la web de IMDb ni se actualizan las puntuaciones desde Internet.

| Código | Episodio | Puntuación | Votos |
|---|---|---:|---:|
| S01E01 | The Hedge Knight | 9.2 | 45120 |
| S01E02 | Hard Salt Beef | 8.8 | 38900 |
| S01E03 | The Squire | 9.5 | 52400 |
| S01E04 | Seven | 9.1 | 41200 |
| S01E05 | In the Name of the Mother | 9.7 | 68300 |
| S01E06 | The Morrow | 9.4 | 49800 |

## Requisitos y compilación

Se utiliza Linux, GCC, GNU Make y `ar`. El programa puede ejecutarse en
GitHub Codespaces o en Ubuntu, incluido Ubuntu mediante WSL. Python 3 solo
se necesita para las pruebas adicionales de red; el servidor y el cliente
están escritos en C.

Desde la raíz del repositorio:

```bash
make all
```

Esto compila los módulos auxiliares, crea `libmonitor.a` con `ar rcs` y genera
los ejecutables `server` y `client`. Para eliminar los objetos, la biblioteca
y los ejecutables:

```bash
make clean
```

Después de limpiar, se debe ejecutar `make all` antes de utilizar de nuevo
el servidor y el cliente.

## Ejemplo de uso

En una primera terminal, iniciar el servidor:

```bash
./server
```

El servidor escucha en el puerto **TCP 6666** y muestra su PID.
En otra terminal de la misma máquina, consultar un episodio:

```bash
./client S01E05
```

La respuesta esperada es:

```text
Codigo: S01E05
Episodio: In the Name of the Mother
Puntuacion IMDb: 9.7
Votos: 68300
```

La dirección del servidor es opcional; si no se indica, se usa `127.0.0.1`:

```bash
./client S01E01 127.0.0.1
```

El servidor ignora `SIGINT`, por lo que pulsar Ctrl+C no lo termina. Para
cerrarlo, ejecutar desde la segunda terminal `kill -TERM` seguido del PID
del padre que aparece al iniciar. Por ejemplo, si el PID mostrado fuera 1234:

```bash
kill -TERM 1234
```

Ese número es solo un ejemplo: debe sustituirse por el PID de la ejecución actual.

## Organización y decisiones de diseño

- `bd_episodios.h` y `bd_episodios.c` definen la estructura `Episodio`, la tabla
  de seis registros y la búsqueda por código exacto.
- `utilidades.h` y `utilidades.c` implementan lectura completa del código,
  escritura completa y formato de respuesta. Sus objetos y el de la base de
  datos se empaquetan en `libmonitor.a`.
- `server.c` acepta conexiones con `accept()` y crea un hijo con `fork()`
  para cada una. Cada hijo cierra el socket de escucha heredado y atiende
  una consulta; el padre cierra su copia del socket del cliente.
- Antes de leer la consulta, el hijo envía la IP a su padre mediante una
  tubería sin nombre creada con `pipe()`. El padre la lee y muestra la IP
  junto al PID del hijo correspondiente. Se utiliza una tubería por conexión
  para mantener clara esa correspondencia.
- `sigaction()` instala el tratamiento de `SIGCHLD`. El manejador recoge
  los hijos terminados con `waitpid(-1, NULL, WNOHANG)` y conserva `errno`.
  La impresión de mensajes se realiza fuera del manejador.
- `SIGINT` y `SIGPIPE` se ignoran. `SIGTERM` solicita el cierre del padre,
  que deja de aceptar conexiones y espera a los hijos que ya estaban activos.
- El socket de escucha no es bloqueante y se espera actividad mediante
  `poll()`, para comprobar también la solicitud de cierre.
- `client.c` comprueba el formato del código, se conecta por IPv4, envía
  la consulta y recibe la respuesta hasta el cierre de la conexión.
- `red.h` reúne el puerto y el tiempo de espera utilizados por ambos programas.

El protocolo utiliza **seis bytes por consulta**, por ejemplo `S01E01`, sin
incluir el terminador `\0` ni un salto de línea. Se atiende una consulta por
conexión. La respuesta es texto y su final se indica cerrando la conexión.
Las funciones de lectura y escritura repiten las operaciones cuando hace falta,
porque TCP no garantiza que todos los bytes lleguen en una sola lectura.

Las operaciones de recepción y envío tienen un tiempo de espera de cinco
segundos. Un código inexistente produce una respuesta que empieza por `ERROR:`.
El cliente devuelve un código de salida distinto de cero ante errores de uso,
comunicación o una respuesta de error del servidor.

## Pruebas

Con el puerto 6666 libre, ejecutar la comprobación requerida:

```bash
./server --test-run
```

Este modo ejecuta `make all`, verifica el acceso a la tabla, inicia un servidor
de prueba y consulta los seis episodios mediante conexiones TCP. Después
detiene ese servidor. Devuelve **0** si las comprobaciones pasan y un valor
distinto de cero si hay un error, por ejemplo, un fallo de compilación o el
puerto ocupado.

Para ejecutar las pruebas de utilidades, la comprobación anterior y las
pruebas adicionales de red:

```bash
make test
```

Las pruebas adicionales comprueban los datos de los seis episodios, el cliente
real, solicitudes incompletas y fragmentadas, códigos inválidos, 60 consultas
concurrentes, la relación padre-hijo y el registro de IP y PID, el tratamiento
de SIGINT, clientes lentos, recogida de hijos, descriptores y desconexiones.
Las comprobaciones de procesos utilizan `/proc` de Linux.

## Capturas de funcionamiento

Las capturas reales de ejecución deben guardarse en la carpeta `screenshot/`.
Deben mostrar al menos un ejemplo de consulta con su respuesta y el registro
de IP y PID en el servidor. También puede incluirse una captura del resultado
de las pruebas.

## Estado de preparación de la entrega

Antes del envío final, completar el nombre del tercer integrante, comprobar
que los miembros estén unidos a **The Sopranos** en Classroom y añadir las
capturas de `screenshot/`. Los nombres y archivos requeridos deben mantenerse
en la raíz del repositorio. Los objetos `.o` son intermedios; la biblioteca
`libmonitor.a` y los ejecutables `server` y `client` se incluyen según la
orientación.
