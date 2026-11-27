# Comprobación del proyecto

Esta guía explica cómo comprobar la compilación y el funcionamiento
del cliente y del servidor en Linux.

## Preparación

Se necesitan GCC, Make y Python 3. Python se utiliza únicamente
para las pruebas adicionales; el cliente y el servidor están
implementados en C.

Antes de comenzar, detener cualquier instancia anterior del servidor
para dejar libre el puerto TCP 6666.

## Compilar desde cero

```bash
make clean
make all
```

La compilación debe generar libmonitor.a, server y client.

## Prueba integrada del servidor

```bash
./server --test-run
echo $?
```

El modo de prueba comprueba la compilación, los datos de los
episodios y las respuestas mediante conexiones TCP reales.
Un código de salida 0 indica que terminó correctamente.

## Conjunto completo de pruebas

```bash
make test
```

Este comando ejecuta las pruebas de las utilidades, la prueba
integrada del servidor y las pruebas adicionales de red.

Las comprobaciones de red incluyen consultas de los seis episodios,
códigos inexistentes, solicitudes fragmentadas o incompletas,
clientes concurrentes y desconexiones abruptas.

También se comprueba el manejo de SIGINT, la recogida de procesos
hijos y la ausencia de acumulación de descriptores en el padre.

## Comprobación manual

En una terminal:

```bash
./server
```

En otra terminal:

```bash
./client S01E05
```

La respuesta debe contener:

```text
Codigo: S01E05
Episodio: In the Name of the Mother
Puntuacion IMDb: 9.7
Votos: 68300
```

En la terminal del servidor deben aparecer la dirección IP del
cliente y el PID del hijo que atendió la conexión.

Para finalizar, ejecutar desde otra terminal:

```bash
kill -TERM PID
```

Sustituir PID por el identificador del proceso padre mostrado
al iniciar el servidor.

## Interpretación

Una compilación correcta no sustituye las pruebas de funcionamiento.
Las pruebas verifican los casos incluidos, pero no garantizan la
ausencia absoluta de errores ni sustituyen la evaluación del profesor.
