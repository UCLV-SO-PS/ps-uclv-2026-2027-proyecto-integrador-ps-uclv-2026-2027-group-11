#ifndef BD_EPISODIOS_H
#define BD_EPISODIOS_H

#define NUM_EPISODIOS 6

typedef struct {
    char codigo[7];
    const char *titulo;
    double puntuacion;
    unsigned int votos;
} Episodio;

extern const Episodio bd_episodios[NUM_EPISODIOS];

const Episodio *buscar_episodio(const char *codigo);

#endif
