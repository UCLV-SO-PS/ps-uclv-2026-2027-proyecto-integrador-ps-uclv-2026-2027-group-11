#!/usr/bin/env bash
set -euo pipefail
test -f bd_episodios.h && test -f bd_episodios.c || { echo "Ejecuta el script en la carpeta del proyecto." >&2; exit 1; }
for archivo in utilidades.h utilidades.c pruebas/prueba_utilidades.c; do
  test ! -e "$archivo" || { echo "Ya existe $archivo. No se sobrescribirá." >&2; exit 1; }
done
mkdir -p pruebas
cat > 'utilidades.h' <<'CONTENIDO_UTILIDADES'
#ifndef UTILIDADES_H
#define UTILIDADES_H

#include <stddef.h>
#include "bd_episodios.h"

#define LONGITUD_CODIGO 6
#define TAM_RESPUESTA 512

/* 1: código completo; 0: conexión cerrada antes de completarlo; -1: error. */
int leer_codigo(int descriptor, char codigo[LONGITUD_CODIGO + 1]);

/* Escribe todos los bytes. Devuelve 0 en caso de éxito o -1 si falla. */
int escribir_todo(int descriptor, const void *datos, size_t longitud);

/* Devuelve la longitud del texto, sin el terminador, o -1 si no cabe. */
int formatear_respuesta(const Episodio *episodio, char *destino, size_t capacidad);

#endif

CONTENIDO_UTILIDADES
cat > 'utilidades.c' <<'CONTENIDO_UTILIDADES'
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include "utilidades.h"

int leer_codigo(int descriptor, char codigo[LONGITUD_CODIGO + 1]) {
    size_t recibidos = 0;

    if (codigo == NULL) {
        errno = EINVAL;
        return -1;
    }
    codigo[0] = '\0';

    while (recibidos < LONGITUD_CODIGO) {
        ssize_t n = read(descriptor, codigo + recibidos,
                         LONGITUD_CODIGO - recibidos);
        if (n == -1) {
            if (errno == EINTR) {
                continue;
            }
            codigo[recibidos] = '\0';
            return -1;
        }
        if (n == 0) {
            codigo[recibidos] = '\0';
            return 0;
        }
        recibidos += (size_t)n;
    }

    codigo[LONGITUD_CODIGO] = '\0';
    return 1;
}

int escribir_todo(int descriptor, const void *datos, size_t longitud) {
    const char *texto = datos;
    size_t enviados = 0;

    if (datos == NULL && longitud != 0) {
        errno = EINVAL;
        return -1;
    }

    while (enviados < longitud) {
        ssize_t n = write(descriptor, texto + enviados, longitud - enviados);
        if (n == -1) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            errno = EIO;
            return -1;
        }
        enviados += (size_t)n;
    }
    return 0;
}

int formatear_respuesta(const Episodio *episodio, char *destino, size_t capacidad) {
    int longitud;

    if (destino == NULL || capacidad == 0) {
        errno = EINVAL;
        return -1;
    }

    if (episodio == NULL) {
        longitud = snprintf(destino, capacidad, "ERROR: episodio no encontrado.\n");
    } else {
        longitud = snprintf(destino, capacidad,
                            "Codigo: %s\nEpisodio: %s\nPuntuacion IMDb: %.1f\nVotos: %u\n",
                            episodio->codigo, episodio->titulo,
                            episodio->puntuacion, episodio->votos);
    }

    if (longitud < 0) {
        return -1;
    }
    if ((size_t)longitud >= capacidad) {
        errno = ENOSPC;
        return -1;
    }
    return longitud;
}

CONTENIDO_UTILIDADES
cat > 'pruebas/prueba_utilidades.c' <<'CONTENIDO_UTILIDADES'
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "utilidades.h"

int main(void) {
    char respuesta[TAM_RESPUESTA];
    char codigo[LONGITUD_CODIGO + 1];
    int canal[2];
    int estado;

    const Episodio *episodio = buscar_episodio("S01E05");
    assert(episodio != NULL);
    int n = formatear_respuesta(episodio, respuesta, sizeof(respuesta));
    assert(n > 0 && (size_t)n == strlen(respuesta));
    assert(strcmp(respuesta,
                  "Codigo: S01E05\nEpisodio: In the Name of the Mother\n"
                  "Puntuacion IMDb: 9.7\nVotos: 68300\n") == 0);
    puts("Correcto: formato del episodio y datos exactos.");

    assert(formatear_respuesta(NULL, respuesta, sizeof(respuesta)) > 0);
    assert(strcmp(respuesta, "ERROR: episodio no encontrado.\n") == 0);
    puts("Correcto: respuesta para un episodio inexistente.");

    char pequeno[4];
    assert(formatear_respuesta(episodio, pequeno, sizeof(pequeno)) == -1);
    assert(errno == ENOSPC && pequeno[3] == '\0');
    assert(formatear_respuesta(episodio, NULL, 0) == -1);
    puts("Correcto: detección de buffers insuficientes o inválidos.");

    /* El hijo envía el código en dos fragmentos separados en el tiempo. */
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, canal) == 0);
    pid_t hijo = fork();
    assert(hijo >= 0);
    if (hijo == 0) {
        close(canal[0]);
        if (escribir_todo(canal[1], "S0", 2) == -1) {
            _exit(1);
        }
        struct timespec pausa = {0, 50000000};
        nanosleep(&pausa, NULL);
        if (escribir_todo(canal[1], "1E05", 4) == -1) {
            _exit(1);
        }
        close(canal[1]);
        _exit(0);
    }
    close(canal[1]);
    assert(leer_codigo(canal[0], codigo) == 1);
    assert(strcmp(codigo, "S01E05") == 0);
    close(canal[0]);
    assert(waitpid(hijo, &estado, 0) == hijo);
    assert(WIFEXITED(estado) && WEXITSTATUS(estado) == 0);
    puts("Correcto: lectura de un código recibido en fragmentos.");

    assert(pipe(canal) == 0);
    assert(escribir_todo(canal[1], "S01", 3) == 0);
    close(canal[1]);
    assert(leer_codigo(canal[0], codigo) == 0);
    assert(strcmp(codigo, "S01") == 0);
    close(canal[0]);
    puts("Correcto: detección de una solicitud incompleta.");

    assert(pipe(canal) == 0);
    close(canal[1]);
    assert(leer_codigo(canal[0], codigo) == 0 && codigo[0] == '\0');
    close(canal[0]);
    puts("Correcto: detección de cierre sin enviar datos.");

    assert(leer_codigo(-1, codigo) == -1 && errno == EBADF);
    assert(escribir_todo(-1, "x", 1) == -1 && errno == EBADF);
    assert(leer_codigo(-1, NULL) == -1 && errno == EINVAL);
    assert(escribir_todo(-1, NULL, 1) == -1 && errno == EINVAL);
    puts("Correcto: errores de descriptor y argumentos inválidos.");

    /* Verifica una transferencia mayor que el buffer de una tubería. */
    assert(pipe(canal) == 0);
    hijo = fork();
    assert(hijo >= 0);
    if (hijo == 0) {
        close(canal[1]);
        char bloque[4096];
        size_t total = 0;
        ssize_t leidos;
        while ((leidos = read(canal[0], bloque, sizeof(bloque))) > 0) {
            for (ssize_t i = 0; i < leidos; i++) {
                if (bloque[i] != 'A') {
                    _exit(1);
                }
            }
            total += (size_t)leidos;
        }
        close(canal[0]);
        _exit(leidos == 0 && total == 1024 * 1024 ? 0 : 1);
    }
    close(canal[0]);
    char *grande = malloc(1024 * 1024);
    assert(grande != NULL);
    memset(grande, 'A', 1024 * 1024);
    assert(escribir_todo(canal[1], grande, 1024 * 1024) == 0);
    free(grande);
    close(canal[1]);
    assert(waitpid(hijo, &estado, 0) == hijo);
    assert(WIFEXITED(estado) && WEXITSTATUS(estado) == 0);
    puts("Correcto: transferencia completa de 1 MiB.");

    assert(signal(SIGPIPE, SIG_IGN) != SIG_ERR);
    assert(pipe(canal) == 0);
    close(canal[0]);
    assert(escribir_todo(canal[1], "x", 1) == -1 && errno == EPIPE);
    close(canal[1]);
    puts("Correcto: error al escribir sin receptor, con SIGPIPE ignorada.");

    puts("Todas las pruebas de utilidades pasaron.");
    return 0;
}

CONTENIDO_UTILIDADES
temporal=$(mktemp -d)
trap 'rm -rf -- "$temporal"' EXIT
gcc -Wall -Wextra -Werror -std=c11 -c bd_episodios.c -o "$temporal/bd_episodios.o"
gcc -Wall -Wextra -Werror -std=c11 -c utilidades.c -o "$temporal/utilidades.o"
ar rcs libmonitor.a "$temporal/bd_episodios.o" "$temporal/utilidades.o"
gcc -Wall -Wextra -Werror -std=c11 -I. pruebas/prueba_utilidades.c libmonitor.a -o "$temporal/prueba_utilidades"
"$temporal/prueba_utilidades"
printf '\nContenido de libmonitor.a:\n'
ar t libmonitor.a
printf '\nNo se ha realizado ningún commit ni push.\n'
git status --short
