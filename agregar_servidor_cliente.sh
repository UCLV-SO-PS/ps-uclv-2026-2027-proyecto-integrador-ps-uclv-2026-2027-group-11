#!/usr/bin/env bash
set -euo pipefail
for archivo in bd_episodios.c bd_episodios.h utilidades.c utilidades.h pruebas/prueba_utilidades.c; do
    test -f "$archivo" || { echo "Falta $archivo. Ejecuta el script en la carpeta del proyecto." >&2; exit 1; }
done
for archivo in server.c client.c red.h Makefile pruebas/test_red.py; do
    test ! -e "$archivo" || { echo "Ya existe $archivo. No se sobrescribirá; comparte el resultado para revisarlo." >&2; exit 1; }
done
cat > 'server.c' <<'ARCHIVO_ETAPA_RED'
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>
#include "red.h"
#include "utilidades.h"

static volatile sig_atomic_t terminar = 0;

static void recoger_hijos(int senal) {
    int error_anterior = errno;
    (void)senal;
    while (waitpid(-1, NULL, WNOHANG) > 0) {
    }
    errno = error_anterior;
}

static void solicitar_salida(int senal) {
    (void)senal;
    terminar = 1;
}

static int configurar_senales(void) {
    struct sigaction accion = {0};
    sigemptyset(&accion.sa_mask);
    accion.sa_handler = SIG_IGN;
    if (sigaction(SIGINT, &accion, NULL) == -1 ||
        sigaction(SIGPIPE, &accion, NULL) == -1) {
        return -1;
    }
    accion.sa_handler = recoger_hijos;
    accion.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    if (sigaction(SIGCHLD, &accion, NULL) == -1) {
        return -1;
    }
    accion.sa_handler = solicitar_salida;
    accion.sa_flags = 0;
    return sigaction(SIGTERM, &accion, NULL);
}

static int crear_socket_servidor(void) {
    int escucha = socket(AF_INET, SOCK_STREAM, 0);
    if (escucha == -1) {
        return -1;
    }
    int reutilizar = 1;
    struct sockaddr_in direccion = {0};
    direccion.sin_family = AF_INET;
    direccion.sin_addr.s_addr = htonl(INADDR_ANY);
    direccion.sin_port = htons(PUERTO_SERVIDOR);

    if (setsockopt(escucha, SOL_SOCKET, SO_REUSEADDR,
                   &reutilizar, sizeof(reutilizar)) == -1 ||
        bind(escucha, (struct sockaddr *)&direccion, sizeof(direccion)) == -1 ||
        listen(escucha, 32) == -1) {
        int error = errno;
        close(escucha);
        errno = error;
        return -1;
    }
    /* Evita quedar bloqueado en accept si se interrumpe el servidor. */
    int banderas = fcntl(escucha, F_GETFL);
    if (banderas == -1 || fcntl(escucha, F_SETFL, banderas | O_NONBLOCK) == -1) {
        int error = errno;
        close(escucha);
        errno = error;
        return -1;
    }
    return escucha;
}

static int atender_cliente(int conexion) {
    struct timeval espera = {TIEMPO_ESPERA, 0};
    if (setsockopt(conexion, SOL_SOCKET, SO_RCVTIMEO, &espera, sizeof(espera)) == -1 ||
        setsockopt(conexion, SOL_SOCKET, SO_SNDTIMEO, &espera, sizeof(espera)) == -1) {
        return -1;
    }
    char codigo[LONGITUD_CODIGO + 1];
    char respuesta[TAM_RESPUESTA];
    int lectura = leer_codigo(conexion, codigo);
    int longitud;
    if (lectura == 0) {
        longitud = snprintf(respuesta, sizeof(respuesta),
                            "ERROR: codigo incompleto; se requieren 6 caracteres.\n");
    } else if (lectura == -1) {
        longitud = snprintf(respuesta, sizeof(respuesta),
                            "ERROR: no se pudo leer el codigo dentro del tiempo permitido.\n");
    } else {
        longitud = formatear_respuesta(buscar_episodio(codigo), respuesta, sizeof(respuesta));
    }
    if (longitud < 0 || (size_t)longitud >= sizeof(respuesta)) {
        return -1;
    }
    return escribir_todo(conexion, respuesta, (size_t)longitud);
}

static void mostrar_ip_del_hijo(int lector, pid_t hijo) {
    char ip[INET_ADDRSTRLEN] = {0};
    size_t total = 0;
    while (total < sizeof(ip)) {
        ssize_t n = read(lector, ip + total, sizeof(ip) - total);
        if (n == -1 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            break;
        }
        total += (size_t)n;
    }
    close(lector);
    if (total == sizeof(ip)) {
        ip[sizeof(ip) - 1] = '\0';
        printf("IP cliente: %s | PID hijo: %ld\n", ip, (long)hijo);
    } else {
        fprintf(stderr, "El hijo %ld no pudo comunicar la IP.\n", (long)hijo);
    }
}

static int ejecutar_servidor(int escucha) {
    terminar = 0;
    if (configurar_senales() == -1) {
        perror("sigaction");
        close(escucha);
        return EXIT_FAILURE;
    }
    printf("Servidor TCP en puerto %d | PID padre: %ld\n",
           PUERTO_SERVIDOR, (long)getpid());
    printf("SIGINT ignorada. Para terminar: kill -TERM %ld\n", (long)getpid());

    int resultado = EXIT_SUCCESS;
    while (!terminar) {
        struct pollfd evento = {escucha, POLLIN, 0};
        int listo = poll(&evento, 1, 500);
        if (listo == -1 && errno == EINTR) {
            continue;
        }
        if (listo == -1 || (listo > 0 && (evento.revents & (POLLERR | POLLHUP | POLLNVAL)))) {
            fprintf(stderr, "Error al esperar conexiones.\n");
            resultado = EXIT_FAILURE;
            break;
        }
        if (listo == 0 || !(evento.revents & POLLIN) || terminar) {
            continue;
        }
        struct sockaddr_in cliente;
        socklen_t longitud = sizeof(cliente);
        int conexion = accept(escucha, (struct sockaddr *)&cliente, &longitud);
        if (conexion == -1) {
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                perror("accept");
            }
            continue;
        }
        int canal[2];
        if (pipe(canal) == -1) {
            perror("pipe");
            close(conexion);
            continue;
        }
        pid_t hijo = fork();
        if (hijo == -1) {
            perror("fork");
            close(canal[0]);
            close(canal[1]);
            close(conexion);
            continue;
        }
        if (hijo == 0) {
            close(escucha);
            close(canal[0]);
            struct sigaction accion = {0};
            sigemptyset(&accion.sa_mask);
            accion.sa_handler = SIG_DFL;
            if (sigaction(SIGTERM, &accion, NULL) == -1) {
                _exit(EXIT_FAILURE);
            }
            char ip[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &cliente.sin_addr, ip, sizeof(ip)) == NULL ||
                escribir_todo(canal[1], ip, sizeof(ip)) == -1) {
                _exit(EXIT_FAILURE);
            }
            close(canal[1]);
            /* La IP se comunica antes de leer la consulta del cliente. */
            int codigo_salida = atender_cliente(conexion);
            close(conexion);
            _exit(codigo_salida == 0 ? EXIT_SUCCESS : EXIT_FAILURE);
        }
        close(canal[1]);
        close(conexion);
        mostrar_ip_del_hijo(canal[0], hijo);
    }

    close(escucha);
    /* Al cerrar, espera también por los clientes que ya estaban atendidos. */
    while (waitpid(-1, NULL, 0) != -1 || errno == EINTR) {
    }
    puts("Servidor terminado.");
    return resultado;
}

static int esperar_proceso(pid_t proceso) {
    int estado;
    pid_t resultado;
    do {
        resultado = waitpid(proceso, &estado, 0);
    } while (resultado == -1 && errno == EINTR);
    return resultado == proceso && WIFEXITED(estado) && WEXITSTATUS(estado) == 0 ? 0 : -1;
}

static int comprobar_consulta(const Episodio *episodio) {
    int conexion = socket(AF_INET, SOCK_STREAM, 0);
    if (conexion == -1) {
        return -1;
    }
    struct timeval espera = {TIEMPO_ESPERA, 0};
    struct sockaddr_in direccion = {0};
    direccion.sin_family = AF_INET;
    direccion.sin_port = htons(PUERTO_SERVIDOR);
    direccion.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (setsockopt(conexion, SOL_SOCKET, SO_RCVTIMEO, &espera, sizeof(espera)) == -1 ||
        setsockopt(conexion, SOL_SOCKET, SO_SNDTIMEO, &espera, sizeof(espera)) == -1 ||
        connect(conexion, (struct sockaddr *)&direccion, sizeof(direccion)) == -1 ||
        escribir_todo(conexion, episodio->codigo, LONGITUD_CODIGO) == -1 ||
        shutdown(conexion, SHUT_WR) == -1) {
        close(conexion);
        return -1;
    }
    char recibido[TAM_RESPUESTA];
    size_t total = 0;
    while (total < sizeof(recibido) - 1) {
        ssize_t n = read(conexion, recibido + total, sizeof(recibido) - 1 - total);
        if (n == -1 && errno == EINTR) {
            continue;
        }
        if (n == -1) {
            close(conexion);
            return -1;
        }
        if (n == 0) {
            break;
        }
        total += (size_t)n;
    }
    close(conexion);
    recibido[total] = '\0';
    char esperado[TAM_RESPUESTA];
    if (formatear_respuesta(episodio, esperado, sizeof(esperado)) < 0 ||
        strcmp(recibido, esperado) != 0) {
        return -1;
    }
    printf("Prueba TCP correcta: %s\n", episodio->codigo);
    return 0;
}

static int ejecutar_prueba(void) {
    puts("Prueba automática: comprobando compilación con make all.");
    pid_t compilacion = fork();
    if (compilacion == -1) {
        perror("fork");
        return EXIT_FAILURE;
    }
    if (compilacion == 0) {
        execlp("make", "make", "all", (char *)NULL);
        perror("make");
        _exit(EXIT_FAILURE);
    }
    if (esperar_proceso(compilacion) == -1) {
        fprintf(stderr, "La compilación no terminó correctamente.\n");
        return EXIT_FAILURE;
    }
    for (int i = 0; i < NUM_EPISODIOS; i++) {
        if (buscar_episodio(bd_episodios[i].codigo) != &bd_episodios[i]) {
            fprintf(stderr, "Error al inicializar o consultar la base de datos.\n");
            return EXIT_FAILURE;
        }
    }
    int escucha = crear_socket_servidor();
    if (escucha == -1) {
        perror("No se pudo abrir el puerto de prueba 6666");
        return EXIT_FAILURE;
    }
    pid_t servidor = fork();
    if (servidor == -1) {
        perror("fork");
        close(escucha);
        return EXIT_FAILURE;
    }
    if (servidor == 0) {
        _exit(ejecutar_servidor(escucha));
    }
    close(escucha);
    int resultado = EXIT_SUCCESS;
    for (int i = 0; i < NUM_EPISODIOS; i++) {
        if (comprobar_consulta(&bd_episodios[i]) == -1) {
            fprintf(stderr, "Falló la prueba TCP de %s.\n", bd_episodios[i].codigo);
            resultado = EXIT_FAILURE;
            break;
        }
    }
    if (kill(servidor, SIGTERM) == -1 || esperar_proceso(servidor) == -1) {
        resultado = EXIT_FAILURE;
    }
    if (resultado == EXIT_SUCCESS) {
        puts("--test-run: todas las comprobaciones pasaron.");
    }
    return resultado;
}

int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 2 && strcmp(argv[1], "--test-run") == 0) {
        return ejecutar_prueba();
    }
    if (argc != 1) {
        fprintf(stderr, "Uso: %s [--test-run]\n", argv[0]);
        return EXIT_FAILURE;
    }
    int escucha = crear_socket_servidor();
    if (escucha == -1) {
        perror("No se pudo iniciar el servidor en el puerto 6666");
        return EXIT_FAILURE;
    }
    return ejecutar_servidor(escucha);
}

ARCHIVO_ETAPA_RED
cat > 'client.c' <<'ARCHIVO_ETAPA_RED'
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include "red.h"
#include "utilidades.h"

int main(int argc, char *argv[]) {
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "Uso: %s CODIGO [IP_SERVIDOR]\nEjemplo: %s S01E01 127.0.0.1\n",
                argv[0], argv[0]);
        return EXIT_FAILURE;
    }
    const char *codigo = argv[1];
    if (strlen(codigo) != LONGITUD_CODIGO || codigo[0] != 'S' || codigo[3] != 'E' ||
        !isdigit((unsigned char)codigo[1]) || !isdigit((unsigned char)codigo[2]) ||
        !isdigit((unsigned char)codigo[4]) || !isdigit((unsigned char)codigo[5])) {
        fprintf(stderr, "El código debe tener seis caracteres, por ejemplo S01E01.\n");
        return EXIT_FAILURE;
    }

    struct sockaddr_in destino = {0};
    destino.sin_family = AF_INET;
    destino.sin_port = htons(PUERTO_SERVIDOR);
    const char *ip = argc == 3 ? argv[2] : "127.0.0.1";
    if (inet_pton(AF_INET, ip, &destino.sin_addr) != 1) {
        fprintf(stderr, "Dirección IPv4 no válida: %s\n", ip);
        return EXIT_FAILURE;
    }

    struct sigaction ignorar = {0};
    sigemptyset(&ignorar.sa_mask);
    ignorar.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &ignorar, NULL) == -1) {
        perror("sigaction");
        return EXIT_FAILURE;
    }

    int conexion = socket(AF_INET, SOCK_STREAM, 0);
    if (conexion == -1) {
        perror("socket");
        return EXIT_FAILURE;
    }
    struct timeval espera = {TIEMPO_ESPERA, 0};
    if (setsockopt(conexion, SOL_SOCKET, SO_RCVTIMEO, &espera, sizeof(espera)) == -1 ||
        setsockopt(conexion, SOL_SOCKET, SO_SNDTIMEO, &espera, sizeof(espera)) == -1 ||
        connect(conexion, (struct sockaddr *)&destino, sizeof(destino)) == -1 ||
        escribir_todo(conexion, codigo, LONGITUD_CODIGO) == -1 ||
        shutdown(conexion, SHUT_WR) == -1) {
        perror("No se pudo enviar la consulta");
        close(conexion);
        return EXIT_FAILURE;
    }

    char respuesta[TAM_RESPUESTA];
    size_t total = 0;
    while (total < sizeof(respuesta) - 1) {
        ssize_t n = read(conexion, respuesta + total, sizeof(respuesta) - 1 - total);
        if (n == -1 && errno == EINTR) {
            continue;
        }
        if (n == -1) {
            perror("No se pudo recibir la respuesta");
            close(conexion);
            return EXIT_FAILURE;
        }
        if (n == 0) {
            break;
        }
        total += (size_t)n;
    }
    close(conexion);
    if (total == 0 || total == sizeof(respuesta) - 1) {
        fprintf(stderr, "La respuesta está vacía o supera el tamaño permitido.\n");
        return EXIT_FAILURE;
    }
    respuesta[total] = '\0';
    if (escribir_todo(STDOUT_FILENO, respuesta, total) == -1) {
        perror("No se pudo mostrar la respuesta");
        return EXIT_FAILURE;
    }
    return strncmp(respuesta, "ERROR:", 6) == 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}

ARCHIVO_ETAPA_RED
cat > 'red.h' <<'ARCHIVO_ETAPA_RED'
#ifndef RED_H
#define RED_H

#define PUERTO_SERVIDOR 6666
#define TIEMPO_ESPERA 5

#endif

ARCHIVO_ETAPA_RED
cat > 'Makefile' <<'ARCHIVO_ETAPA_RED'
CC = gcc
AR = ar
CPPFLAGS = -D_POSIX_C_SOURCE=200809L
CFLAGS = -Wall -Wextra -Werror -std=c11 -O2

.PHONY: all clean test

all: libmonitor.a server client

libmonitor.a: bd_episodios.o utilidades.o
	$(AR) rcs $@ $^

server: server.o libmonitor.a
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ server.o libmonitor.a $(LDLIBS)

client: client.o libmonitor.a
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ client.o libmonitor.a $(LDLIBS)

bd_episodios.o: bd_episodios.c bd_episodios.h
utilidades.o: utilidades.c utilidades.h bd_episodios.h
server.o: server.c red.h utilidades.h bd_episodios.h
client.o: client.c red.h utilidades.h bd_episodios.h

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

test: all
	$(CC) $(CPPFLAGS) $(CFLAGS) -I. pruebas/prueba_utilidades.c libmonitor.a -o /tmp/prueba_utilidades_sopranos
	/tmp/prueba_utilidades_sopranos
	./server --test-run
	python3 -m unittest discover -s pruebas -p 'test_red.py' -v

clean:
	rm -f *.o libmonitor.a server client

ARCHIVO_ETAPA_RED
cat > 'pruebas/test_red.py' <<'ARCHIVO_ETAPA_RED'
"""Pruebas reales de TCP, procesos y señales. Requieren el puerto 6666 libre."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import re
import signal
import socket
import subprocess
import tempfile
import time
import unittest

RAIZ = Path(__file__).resolve().parents[1]
EPISODIOS = [
    ("S01E01", "The Hedge Knight", "9.2", 45120),
    ("S01E02", "Hard Salt Beef", "8.8", 38900),
    ("S01E03", "The Squire", "9.5", 52400),
    ("S01E04", "Seven", "9.1", 41200),
    ("S01E05", "In the Name of the Mother", "9.7", 68300),
    ("S01E06", "The Morrow", "9.4", 49800),
]


def recibir(conexion):
    """Lee hasta que el servidor cierre su extremo de la conexión."""
    partes = []
    while True:
        datos = conexion.recv(512)
        if not datos:
            return b"".join(partes).decode("utf-8")
        partes.append(datos)


def consultar(codigo):
    """Realiza una consulta con un cliente TCP independiente del programa en C."""
    with socket.create_connection(("127.0.0.1", 6666), timeout=8) as conexion:
        conexion.sendall(codigo.encode("ascii"))
        conexion.shutdown(socket.SHUT_WR)
        return recibir(conexion)


def respuesta_esperada(episodio):
    """Construye la respuesta esperada a partir de los datos de la orientación."""
    codigo, titulo, puntuacion, votos = episodio
    return (f"Codigo: {codigo}\nEpisodio: {titulo}\n"
            f"Puntuacion IMDb: {puntuacion}\nVotos: {votos}\n")


def hijos_del_proceso(padre):
    """Consulta PPid y estado en /proc, sin depender del archivo opcional children."""
    hijos = {}
    for directorio in Path("/proc").iterdir():
        if not directorio.name.isdecimal():
            continue
        try:
            lineas = (directorio / "status").read_text().splitlines()
            campos = dict(linea.split(":", 1) for linea in lineas if ":" in linea)
            if campos.get("PPid", "").strip() == str(padre):
                hijos[directorio.name] = campos["State"].strip().split()[0]
        except (OSError, KeyError):
            # Un proceso puede terminar mientras se recorre /proc.
            continue
    return hijos


class PruebasServidor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporal = tempfile.TemporaryDirectory()
        cls.ruta_registro = Path(cls.temporal.name) / "servidor.log"
        cls.registro = cls.ruta_registro.open("w")
        cls.proceso = subprocess.Popen(
            [str(RAIZ / "server")], cwd=RAIZ, stdout=cls.registro,
            stderr=cls.registro, start_new_session=True)
        for _ in range(100):
            if cls.proceso.poll() is not None:
                mensaje = cls.ruta_registro.read_text()
                cls.registro.close()
                cls.temporal.cleanup()
                raise RuntimeError("No se pudo iniciar el servidor de pruebas: " + mensaje)
            if "Servidor TCP en puerto" in cls.ruta_registro.read_text():
                break
            time.sleep(0.02)
        else:
            cls.proceso.kill()
            cls.proceso.wait()
            cls.registro.close()
            cls.temporal.cleanup()
            raise RuntimeError("El servidor no terminó de iniciarse.")

    @classmethod
    def tearDownClass(cls):
        cls.proceso.terminate()
        try:
            cls.proceso.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(cls.proceso.pid, signal.SIGKILL)
            cls.proceso.wait()
        cls.registro.close()
        cls.temporal.cleanup()

    def ejecutar_cliente(self, *argumentos):
        """Ejecuta el cliente real y devuelve su resultado."""
        return subprocess.run([str(RAIZ / "client"), *argumentos], cwd=RAIZ,
                              capture_output=True, text=True, timeout=8)

    def test_01_seis_episodios_exactos_por_tcp(self):
        for episodio in EPISODIOS:
            with self.subTest(codigo=episodio[0]):
                self.assertEqual(consultar(episodio[0]), respuesta_esperada(episodio))

    def test_02_cliente_real(self):
        for episodio in EPISODIOS:
            with self.subTest(codigo=episodio[0]):
                resultado = self.ejecutar_cliente(episodio[0], "127.0.0.1")
                self.assertEqual(resultado.returncode, 0, resultado.stderr)
                self.assertEqual(resultado.stdout, respuesta_esperada(episodio))

    def test_03_episodio_inexistente(self):
        self.assertEqual(consultar("S01E99"), "ERROR: episodio no encontrado.\n")
        resultado = self.ejecutar_cliente("S01E99")
        self.assertNotEqual(resultado.returncode, 0)
        self.assertIn("ERROR:", resultado.stdout)

    def test_04_codigo_fragmentado(self):
        with socket.create_connection(("127.0.0.1", 6666), timeout=8) as conexion:
            conexion.sendall(b"S0")
            conexion.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                conexion.recv(512)
            conexion.settimeout(8)
            conexion.sendall(b"1E05")
            conexion.shutdown(socket.SHUT_WR)
            self.assertEqual(recibir(conexion), respuesta_esperada(EPISODIOS[4]))

    def test_05_solicitud_incompleta(self):
        self.assertIn("codigo incompleto", consultar("S01"))

    def test_06_codigo_con_terminador_interno(self):
        self.assertIn("ERROR:", consultar("S0\x00E01"))

    def test_07_sesenta_clientes_concurrentes(self):
        peticiones = EPISODIOS * 10
        with ThreadPoolExecutor(max_workers=20) as grupo:
            resultados = list(grupo.map(lambda e: consultar(e[0]), peticiones))
        self.assertEqual(resultados, [respuesta_esperada(e) for e in peticiones])

    @unittest.skipUnless(Path("/proc/self/stat").exists(), "Requiere /proc de Linux")
    def test_08_procesos_distintos_ip_y_sigint(self):
        conexiones = [socket.create_connection(("127.0.0.1", 6666), timeout=8)
                      for _ in range(3)]
        try:
            for _ in range(100):
                hijos = hijos_del_proceso(self.proceso.pid)
                registros = self.ruta_registro.read_text()
                if len(hijos) >= 3 and all(
                    estado != "Z" and f"PID hijo: {hijo}\n" in registros
                    for hijo, estado in hijos.items()
                ):
                    break
                time.sleep(0.01)
            self.assertGreaterEqual(len(hijos), 3)
            for hijo in hijos:
                estado = Path(f"/proc/{hijo}/status").read_text()
                self.assertIn(f"PPid:\t{self.proceso.pid}\n", estado)
            for hijo in hijos:
                self.assertIn(f"IP cliente: 127.0.0.1 | PID hijo: {hijo}", registros)
            # Envía SIGINT al padre y sus hijos, como hace una terminal con Ctrl+C.
            os.killpg(self.proceso.pid, signal.SIGINT)
            self.assertIsNone(self.proceso.poll())
            for conexion in conexiones:
                conexion.sendall(b"S01E01")
                conexion.shutdown(socket.SHUT_WR)
                self.assertEqual(recibir(conexion), respuesta_esperada(EPISODIOS[0]))
        finally:
            for conexion in conexiones:
                conexion.close()

    def test_09_cliente_lento_no_bloquea_a_otro(self):
        with socket.create_connection(("127.0.0.1", 6666), timeout=8) as lento:
            lento.sendall(b"S01")
            inicio = time.monotonic()
            self.assertEqual(consultar("S01E06"), respuesta_esperada(EPISODIOS[5]))
            self.assertLess(time.monotonic() - inicio, 2)
            self.assertIn("tiempo permitido", recibir(lento))

    @unittest.skipUnless(Path("/proc/self/stat").exists(), "Requiere /proc de Linux")
    def test_10_sin_zombis_ni_fugas_de_descriptores(self):
        for _ in range(30):
            consultar("S01E01")
        for _ in range(100):
            if not hijos_del_proceso(self.proceso.pid):
                break
            time.sleep(0.01)
        self.assertEqual(hijos_del_proceso(self.proceso.pid), {})
        # stdin, stdout, stderr y socket de escucha; ningún descriptor por cliente queda abierto.
        self.assertEqual(len(list(Path(f"/proc/{self.proceso.pid}/fd").iterdir())), 4)

    def test_11_argumentos_invalidos_del_cliente(self):
        for argumentos in [(), ("S01",), ("s01e01",), ("S01E01X",),
                           ("S01E01", "no-es-ip"), ("S01E01", "127.0.0.1", "extra")]:
            with self.subTest(argumentos=argumentos):
                self.assertNotEqual(self.ejecutar_cliente(*argumentos).returncode, 0)

    def test_12_puerto_ocupado_se_informa_sin_interferir(self):
        resultado = subprocess.run([str(RAIZ / "server")], cwd=RAIZ,
                                   capture_output=True, text=True, timeout=8)
        self.assertNotEqual(resultado.returncode, 0)
        self.assertIn("puerto 6666", resultado.stderr)
        self.assertEqual(consultar("S01E02"), respuesta_esperada(EPISODIOS[1]))

    def test_13_desconexion_abrupta(self):
        for _ in range(10):
            conexion = socket.create_connection(("127.0.0.1", 6666), timeout=8)
            conexion.sendall(b"S01E01")
            conexion.close()
        self.assertEqual(consultar("S01E03"), respuesta_esperada(EPISODIOS[2]))


if __name__ == "__main__":
    unittest.main(verbosity=2)

ARCHIVO_ETAPA_RED
# Solo se excluyen archivos intermedios; los binarios y la biblioteca se conservan.
if ! test -e .gitignore; then
    printf '*.o\n__pycache__/\n*.pyc\n' > .gitignore
fi
make all
make test
printf '\nServidor, cliente, biblioteca y pruebas preparados.\n'
printf 'No se ha realizado ningún commit ni push.\n'
git status --short
