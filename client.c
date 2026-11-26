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

