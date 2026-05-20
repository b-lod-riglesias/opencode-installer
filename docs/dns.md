# DNS interno

El instalador deriva el DNS interno a partir de la IP principal del host.

Ejemplos:

- `10.20.20.50` usa `10.20.20.254`
- `10.20.10.50` usa `10.20.10.254`

Cuando `systemd-resolved` esta disponible, el script crea:

```text
/etc/systemd/resolved.conf.d/opencode-litellm-dns.conf
```

con `DNS=<red>.254` y `Domains=~cpd.local`, para que `lllm.cpd.local` resuelva por el DNS interno. `/etc/hosts` queda solo como fallback manual si el usuario introduce una IP durante la instalacion.
