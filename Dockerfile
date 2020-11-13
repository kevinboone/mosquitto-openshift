FROM alpine:3.11

RUN addgroup -g 1000 mygroup && \
    adduser -G mygroup -u 1000 -h /myuser -D myuser && \
    chown -R myuser:mygroup /myuser && \
    apk --no-cache add mosquitto 

WORKDIR /myuser

COPY files/* /myuser/

USER myuser

EXPOSE 1883 8883

CMD ["/myuser/start.sh"]

