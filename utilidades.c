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

