#include <stddef.h>
#include <string.h>
#include "bd_episodios.h"

const Episodio bd_episodios[NUM_EPISODIOS] = {
    {"S01E01", "The Hedge Knight",          9.2, 45120},
    {"S01E02", "Hard Salt Beef",           8.8, 38900},
    {"S01E03", "The Squire",               9.5, 52400},
    {"S01E04", "Seven",                    9.1, 41200},
    {"S01E05", "In the Name of the Mother",9.7, 68300},
    {"S01E06", "The Morrow",               9.4, 49800}
};

const Episodio *buscar_episodio(const char *codigo) {
    if (codigo == NULL || strlen(codigo) != 6) {
        return NULL;
    }

    for (int i = 0; i < NUM_EPISODIOS; i++) {
        if (strcmp(bd_episodios[i].codigo, codigo) == 0) {
            return &bd_episodios[i];
        }
    }

    return NULL;
}
