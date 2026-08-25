package com.example.messages;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(MessageController.class)
class MessageControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void messagesIdentifiesBackend() throws Exception {
        mockMvc.perform(get("/messages"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.backend").value("java"))
                .andExpect(jsonPath("$.message").value(containsString("Spring Boot")));
    }

    @Test
    void messagesEchoesForwardHeadersWhenPresent() throws Exception {
        mockMvc.perform(get("/messages")
                        .header("X-Forwarded-Proto", "https")
                        .header("X-Forwarded-Port", "443"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.x_forwarded_proto").value("https"))
                .andExpect(jsonPath("$.x_forwarded_port").value("443"));
    }

    @Test
    void unknownPathIs404() throws Exception {
        mockMvc.perform(get("/nope")).andExpect(status().isNotFound());
    }
}
