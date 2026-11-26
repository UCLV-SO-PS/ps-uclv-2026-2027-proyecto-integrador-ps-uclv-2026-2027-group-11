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

