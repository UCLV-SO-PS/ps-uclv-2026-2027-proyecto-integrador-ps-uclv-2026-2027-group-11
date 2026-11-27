# Guía de uso

Este proyecto permite consultar los datos de seis episodios mediante
un cliente y un servidor TCP. Para ejecutarlo se necesita Linux,
GCC y Make.

## Compilar

Desde la carpeta principal del proyecto:

```bash
make all
```

Este comando genera la biblioteca estática libmonitor.a y los
ejecutables server y client.

## Iniciar el servidor

En una terminal:

```bash
./server
```

El servidor escucha en el puerto 6666. La terminal muestra el PID del
proceso padre y, al recibir conexiones, la IP del cliente y el PID
del hijo que atiende cada conexión.

## Consultar un episodio

Con el servidor funcionando, abrir otra terminal y ejecutar:

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

Los códigos disponibles van desde S01E01 hasta S01E06.

Por defecto, el cliente se conecta a 127.0.0.1. Para consultar un
servidor en otra computadora, se indica su dirección IPv4:

```bash
./client S01E05 192.168.1.10
```

La dirección es un ejemplo y debe sustituirse por la del servidor.
Ambas computadoras deben tener conectividad y permitir la conexión
TCP al puerto 6666.

## Consultar un código inexistente

```bash
./client S01E99
```

El servidor responde:

```text
ERROR: episodio no encontrado.
```

## Detener el servidor

El servidor ignora SIGINT, por lo que Ctrl+C no lo termina.
Desde otra terminal, ejecutar:

```bash
kill -TERM PID
```

Sustituir PID por el número del proceso padre mostrado al iniciar
el servidor.

## Ejecutar las pruebas

Con el servidor anterior detenido y el puerto 6666 libre:

```bash
make test
```

Las pruebas comprueban las utilidades, las consultas TCP y el
comportamiento con varios clientes.

## Limpiar los archivos generados

```bash
make clean
```

Este comando elimina los objetos, la biblioteca y los ejecutables.
Para volver a utilizarlos, ejecutar make all.


## Problemas frecuentes

### El cliente no puede conectarse

Comprobar que el servidor está iniciado, que la dirección IPv4
es correcta y que el puerto TCP 6666 permite conexiones.
Si ambos programas se ejecutan en el mismo Codespace, utilizar:

```bash
./client S01E01
```

### El servidor indica que el puerto está ocupado

Puede haber otra instancia del servidor ejecutándose.
Detener la instancia anterior mediante SIGTERM antes de iniciar
una nueva. No es necesario cambiar el puerto del proyecto.

### Los ejecutables no existen

Si se ejecutó make clean, volver a compilarlos:

```bash
make all
```
