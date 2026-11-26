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

