#include "mqtt.h"

#include <mosquitto.h>

#include "common.h"

Mqtt::Mqtt(const std::string& host, int port, const std::string& clientId) : host_(host), port_(port) {
    mosquitto_lib_init();
    m_ = mosquitto_new(clientId.c_str(), true, this);
    mosquitto_connect_callback_set(m_, [](mosquitto*, void* self, int rc) {
        static_cast<Mqtt*>(self)->connected_ = (rc == 0);
        logf("mqtt: %s", rc == 0 ? "connected" : mosquitto_connack_string(rc));
    });
    mosquitto_disconnect_callback_set(m_, [](mosquitto*, void* self, int) {
        if (static_cast<Mqtt*>(self)->connected_.exchange(false)) logf("mqtt: disconnected, will retry");
    });
    mosquitto_reconnect_delay_set(m_, 1, 10, true);
}

Mqtt::~Mqtt() {
    if (m_) {
        mosquitto_disconnect(m_);
        mosquitto_loop_stop(m_, true);
        mosquitto_destroy(m_);
    }
    mosquitto_lib_cleanup();
}

bool Mqtt::start() {
    int rc = mosquitto_connect_async(m_, host_.c_str(), port_, 30);
    if (rc != MOSQ_ERR_SUCCESS) logf("mqtt: connect_async: %s (will keep retrying)", mosquitto_strerror(rc));
    rc = mosquitto_loop_start(m_);
    if (rc != MOSQ_ERR_SUCCESS) {
        logf("mqtt: loop_start: %s", mosquitto_strerror(rc));
        return false;
    }
    return true;
}

bool Mqtt::publish(const std::string& topic, const std::string& payload, bool retain) {
    if (!connected_) return false;
    int rc = mosquitto_publish(m_, nullptr, topic.c_str(), (int)payload.size(), payload.data(), 0, retain);
    if (rc == MOSQ_ERR_SUCCESS) published_++;
    return rc == MOSQ_ERR_SUCCESS;
}
